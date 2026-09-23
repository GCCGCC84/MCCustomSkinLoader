# A tiny TCP join relay for the game compatibility tests.
#
# Vanilla Minecraft 1.14-1.16.5 with the --server launch argument starts the
# ConnectingScreen (and the connection) before the first resource reload has
# finished. Fabric/Quilt do not change that ordering, so on slow machines the
# world can be rendered before the model registry is populated (MC-145102:
# "Tesselating block in world" NPE). Forge patches Minecraft to open the
# initial screen only after the reload, which is why Forge does not need this.
#
# The relay accepts the client connection on the port the game connects to,
# forwards client->server traffic at full speed, lets small server->client
# frames (keep-alives, position updates, ...) through and holds large frames
# (Join Game, chunk data, ...) until the test harness has seen the resource
# reload finish. The client stays connected in the "Joining world" state and
# keeps answering keep-alives, so neither side times out; once released, the
# chunks are flushed after the models are ready.

Set-StrictMode -Version 1.0

$script:JoinRelaySource = @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Threading;

public static class CslJoinRelay
{
    private sealed class PendingKeepAlive
    {
        public long Nonce;
        public int ClientboundId;
        public DateTime SeenAt;
        public bool Acked;
    }

    private sealed class RelayState
    {
        public readonly MemoryStream Held = new MemoryStream();
        public readonly object Gate = new object();
        public readonly object UpstreamGate = new object();
        public readonly List<PendingKeepAlive> Pending = new List<PendingKeepAlive>();
        public NetworkStream To;
        public NetworkStream Upstream;
        public bool LoginPacketForwarded;
    }

    private static TcpListener listener;
    private static Thread acceptThread;
    private static volatile bool running;
    private static volatile bool released;
    private static int heldFrames;
    private static long heldBytes;
    private static int earlyFlushes;
    private static int keepAliveClientboundId = -1;
    private static int keepAliveServerboundId = -1;
    private static int hintClientboundId = -1;
    private static int hintServerboundId = -1;
    private static int emulatedAcks;
    private static string lastStatus = "idle";
    private static readonly object statusGate = new object();

    public static void Start(int listenPort, int upstreamPort, int threshold, int hintClientbound, int hintServerbound)
    {
        Stop();
        released = false;
        heldFrames = 0;
        heldBytes = 0;
        earlyFlushes = 0;
        keepAliveClientboundId = -1;
        keepAliveServerboundId = -1;
        hintClientboundId = hintClientbound;
        hintServerboundId = hintServerbound;
        emulatedAcks = 0;
        listener = new TcpListener(IPAddress.Loopback, listenPort);
        listener.Start();
        running = true;
        acceptThread = new Thread(() => AcceptLoop(upstreamPort, threshold));
        acceptThread.IsBackground = true;
        acceptThread.Start();
        SetStatus("listening " + listenPort + " -> " + upstreamPort
            + " keepAliveHint=" + FormatId(hintClientbound) + "/" + FormatId(hintServerbound));
    }

    private static string FormatId(int id)
    {
        return id >= 0 ? "0x" + id.ToString("x2") : "?";
    }

    public static void Release()
    {
        released = true;
        SetStatus("released heldFrames=" + Interlocked.CompareExchange(ref heldFrames, 0, 0)
            + " heldBytes=" + Interlocked.Read(ref heldBytes)
            + " earlyFlushes=" + Interlocked.CompareExchange(ref earlyFlushes, 0, 0)
            + " emulatedAcks=" + Interlocked.CompareExchange(ref emulatedAcks, 0, 0)
            + " keepAlive=" + FormatId(keepAliveClientboundId >= 0 ? keepAliveClientboundId : hintClientboundId)
            + "/" + FormatId(keepAliveServerboundId >= 0 ? keepAliveServerboundId : hintServerboundId));
    }

    public static string GetStatus()
    {
        lock (statusGate) { return lastStatus; }
    }

    public static bool IsKeepAliveLearned()
    {
        return keepAliveClientboundId >= 0 && keepAliveServerboundId >= 0;
    }

    public static void Stop()
    {
        running = false;
        var current = listener;
        listener = null;
        if (current != null)
        {
            try { current.Stop(); } catch { }
        }
    }

    private static void SetStatus(string message)
    {
        lock (statusGate) { lastStatus = message + " @ " + DateTime.Now.ToString("HH:mm:ss"); }
    }

    private static void AcceptLoop(int upstreamPort, int threshold)
    {
        while (running)
        {
            TcpClient client;
            try { client = listener.AcceptTcpClient(); }
            catch { break; }
            client.NoDelay = true;
            var thread = new Thread(() => Handle(client, upstreamPort, threshold));
            thread.IsBackground = true;
            thread.Start();
        }
    }

    private static void Handle(TcpClient client, int upstreamPort, int threshold)
    {
        var upstream = new TcpClient();
        try
        {
            upstream.NoDelay = true;
            upstream.Connect(IPAddress.Loopback, upstreamPort);
        }
        catch
        {
            try { client.Close(); } catch { }
            return;
        }

        var state = new RelayState();
        state.To = client.GetStream();
        state.Upstream = upstream.GetStream();

        var send = new Thread(() => PumpToUpstream(client.GetStream(), upstream.GetStream(), state));
        send.IsBackground = true;
        send.Start();
        var receive = new Thread(() => PumpFramed(upstream.GetStream(), state, threshold));
        receive.IsBackground = true;
        receive.Start();
        var flush = new Thread(() => FlushLoop(state));
        flush.IsBackground = true;
        flush.Start();
    }

    private static void PumpToUpstream(NetworkStream from, NetworkStream to, RelayState state)
    {
        try
        {
            while (true)
            {
                int length = ReadVarInt(from);
                if (length < 0) break;
                var frame = new byte[length];
                if (length > 0 && !ReadExact(from, frame, length)) break;

                LearnKeepAliveAck(state, frame, length);

                lock (state.UpstreamGate)
                {
                    WriteVarInt(to, length);
                    if (length > 0) to.Write(frame, 0, length);
                    to.Flush();
                }
            }
        }
        catch { }
        try { to.Close(); } catch { }
    }

    private static void PumpFramed(NetworkStream from, RelayState state, int threshold)
    {
        try
        {
            while (true)
            {
                int length = ReadVarInt(from);
                if (length < 0) break;
                var frame = new byte[length];
                if (length > 0 && !ReadExact(from, frame, length)) break;

                RegisterKeepAlive(state, frame, length);

                lock (state.Gate)
                {
                    if (!released)
                    {
                        if (length > threshold)
                        {
                            // The first large play packet is Join Game (it carries
                            // the dimension registry on 1.16+). Without it the
                            // client's handlers for the follow-up packets throw
                            // NPEs, so always forward it and only hold the world
                            // data that comes after.
                            if (!state.LoginPacketForwarded)
                            {
                                state.LoginPacketForwarded = true;
                            }
                            else
                            {
                                WriteVarInt(state.Held, length);
                                state.Held.Write(frame, 0, length);
                                Interlocked.Increment(ref heldFrames);
                                Interlocked.Add(ref heldBytes, length);
                                continue;
                            }
                        }
                        // Small control frame (keep-alive, position, ...): forward
                        // it, but keep holding the buffered world data.
                        WriteVarInt(state.To, length);
                        if (length > 0) state.To.Write(frame, 0, length);
                        state.To.Flush();
                        continue;
                    }

                    FlushHeld(state);
                    WriteVarInt(state.To, length);
                    if (length > 0) state.To.Write(frame, 0, length);
                    state.To.Flush();
                }
            }
        }
        catch { }
        try { state.To.Close(); } catch { }
    }

    private static void RegisterKeepAlive(RelayState state, byte[] payload, int length)
    {
        // Clientbound keep-alive: packet id VarInt followed by a long nonce.
        if (length < 9 || length > 10) return;
        int id = ReadVarIntFromBytes(payload, length, out int idBytes);
        if (id < 0 || idBytes < 1 || length - idBytes != 8) return;

        int known = keepAliveClientboundId >= 0 ? keepAliveClientboundId : hintClientboundId;
        if (known >= 0 && id != known) return;

        long nonce = ReadInt64(payload, length - 8);
        lock (state.Gate)
        {
            var entry = state.Pending.Find(p => p.Nonce == nonce);
            if (entry == null)
            {
                if (known < 0 && state.Pending.Count >= 8) return;
                state.Pending.Add(new PendingKeepAlive { Nonce = nonce, ClientboundId = id, SeenAt = DateTime.UtcNow });
            }
            else
            {
                entry.SeenAt = DateTime.UtcNow;
            }
        }
    }

    private static void LearnKeepAliveAck(RelayState state, byte[] payload, int length)
    {
        // The client answers a keep-alive with the same long nonce; the matching
        // pair proves the packet ids in both directions.
        if (length < 9 || length > 10) return;
        int id = ReadVarIntFromBytes(payload, length, out int idBytes);
        if (id < 0 || idBytes < 1 || length - idBytes != 8) return;

        long nonce = ReadInt64(payload, length - 8);
        lock (state.Gate)
        {
            var entry = state.Pending.Find(p => p.Nonce == nonce);
            if (entry == null) return;
            entry.Acked = true;
            if (keepAliveServerboundId < 0 || keepAliveClientboundId < 0)
            {
                keepAliveClientboundId = entry.ClientboundId;
                keepAliveServerboundId = id;
                state.Pending.RemoveAll(p => p.Nonce != nonce);
            }
        }
    }

    private static void FlushLoop(RelayState state)
    {
        while (running)
        {
            try
            {
                if (released)
                {
                    lock (state.Gate)
                    {
                        FlushHeld(state);
                        state.To.Flush();
                    }
                }
                EmulateKeepAlives(state);
            }
            catch { return; }
            Thread.Sleep(200);
        }
    }

    private static void EmulateKeepAlives(RelayState state)
    {
        int serverbound = keepAliveServerboundId >= 0 ? keepAliveServerboundId : hintServerboundId;
        if (serverbound < 0 || state.Upstream == null) return;
        lock (state.Gate)
        {
            foreach (var pending in state.Pending)
            {
                if (pending.Acked) continue;
                if ((DateTime.UtcNow - pending.SeenAt).TotalSeconds < 10) continue;
                // The client main thread can be busy with the first terrain
                // render for longer than the server's keep-alive timeout; answer
                // on its behalf so the server does not kick it.
                lock (state.UpstreamGate)
                {
                    WriteVarInt(state.Upstream, 9);
                    WriteVarInt(state.Upstream, serverbound);
                    WriteInt64(state.Upstream, pending.Nonce);
                    state.Upstream.Flush();
                }
                Interlocked.Increment(ref emulatedAcks);
                pending.Acked = true;
            }
            state.Pending.RemoveAll(p => p.Acked && (DateTime.UtcNow - p.SeenAt).TotalSeconds > 60);
        }
    }

    private static void FlushHeld(RelayState state)
    {
        if (state.Held.Length == 0) return;
        if (!released)
        {
            // Never release buffered world data before the harness says the
            // client is ready; keep it as a regression guard.
            Interlocked.Increment(ref earlyFlushes);
            return;
        }
        var data = state.Held.ToArray();
        state.Held.SetLength(0);
        state.Held.Position = 0;
        state.To.Write(data, 0, data.Length);
    }

    private static int ReadVarInt(NetworkStream stream)
    {
        int result = 0;
        for (int i = 0; i < 5; i++)
        {
            int b = stream.ReadByte();
            if (b < 0) return -1;
            result |= (b & 0x7F) << (7 * i);
            if ((b & 0x80) == 0) return result;
        }
        return -1;
    }

    private static void WriteVarInt(Stream stream, int value)
    {
        while (true)
        {
            if ((value & ~0x7F) == 0)
            {
                stream.WriteByte((byte)value);
                return;
            }
            stream.WriteByte((byte)((value & 0x7F) | 0x80));
            value = (int)((uint)value >> 7);
        }
    }

    private static bool ReadExact(NetworkStream stream, byte[] buffer, int count)
    {
        int offset = 0;
        while (offset < count)
        {
            int read = stream.Read(buffer, offset, count - offset);
            if (read <= 0) return false;
            offset += read;
        }
        return true;
    }

    private static int ReadVarIntFromBytes(byte[] buffer, int length, out int bytesRead)
    {
        bytesRead = 0;
        int result = 0;
        for (int i = 0; i < 5 && i < length; i++)
        {
            int b = buffer[i];
            bytesRead = i + 1;
            result |= (b & 0x7F) << (7 * i);
            if ((b & 0x80) == 0) return result;
        }
        return -1;
    }

    private static long ReadInt64(byte[] buffer, int offset)
    {
        long value = 0;
        for (int i = 0; i < 8; i++)
        {
            value = (value << 8) | buffer[offset + i];
        }
        return value;
    }

    private static void WriteInt64(Stream stream, long value)
    {
        for (int i = 7; i >= 0; i--)
        {
            stream.WriteByte((byte)((value >> (8 * i)) & 0xFF));
        }
    }
}
'@

function Initialize-JoinRelay {
    if (-not ('CslJoinRelay' -as [type])) {
        Add-Type -TypeDefinition $script:JoinRelaySource -Language CSharp | Out-Null
    }
}

function Test-JoinRelayRequired {
    param(
        [Parameter(Mandatory)][string]$McVersion,
        [Parameter(Mandatory)][string]$Loader
    )

    # 1.13.2-1.20.1 use the --server auto-connect; the client can reach the
    # world before its first resource reload and terrain pass are done and can
    # be kicked by the server while the main thread is busy. The relay holds
    # the world data until the harness sees the reload finish and answers
    # keep-alives on the client's behalf (MC-145102 and friends). 1.17.0
    # crashes before the connection is even attempted (MC-228828) and 1.20.2+
    # uses quick play.
    if ($McVersion -eq '1.17') {
        return $false
    }
    return ($McVersion -match '^1\.(13|14|15|16|17|18|19|20)(\.\d+)?$' -and $McVersion -notmatch '^1\.20\.[2-9]')
}

function Get-FreeTcpPort {
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    try {
        $listener.Start()
        return ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
    } finally {
        $listener.Stop()
    }
}

function Get-JoinRelayKeepAliveIds {
    param([Parameter(Mandatory)][string]$McVersion)

    # Packet ids verified against PrismarineJS/minecraft-data for the versions
    # where the client is often too busy during the first resource reload to
    # answer the keep-alive (so the relay cannot learn them at runtime).
    $table = @{
        '1.13' = @{ Clientbound = 0x21; Serverbound = 0x0E }
        '1.14' = @{ Clientbound = 0x20; Serverbound = 0x0F }
        '1.15' = @{ Clientbound = 0x21; Serverbound = 0x0F }
    }

    if ($McVersion -match '^(\d+\.\d+)') {
        $key = $Matches[1]
        if ($table.ContainsKey($key)) {
            return $table[$key]
        }
    }
    return $null
}

function Start-JoinRelay {
    param(
        [Parameter(Mandatory)][int]$ListenPort,
        [Parameter(Mandatory)][int]$UpstreamPort,
        [int]$FrameThreshold = 64,
        [int]$ClientboundKeepAliveId = -1,
        [int]$ServerboundKeepAliveId = -1
    )

    Initialize-JoinRelay
    [CslJoinRelay]::Start($ListenPort, $UpstreamPort, $FrameThreshold, $ClientboundKeepAliveId, $ServerboundKeepAliveId)
    return [pscustomobject]@{
        ListenPort     = $ListenPort
        UpstreamPort   = $UpstreamPort
        FrameThreshold = $FrameThreshold
    }
}

function Set-JoinRelayRelease {
    Initialize-JoinRelay
    [CslJoinRelay]::Release()
}

function Get-JoinRelayStatus {
    if (-not ('CslJoinRelay' -as [type])) {
        return 'not started'
    }
    return [CslJoinRelay]::GetStatus()
}

function Test-JoinRelayKeepAliveReady {
    if (-not ('CslJoinRelay' -as [type])) {
        return $false
    }
    return [CslJoinRelay]::IsKeepAliveLearned()
}

function Stop-JoinRelay {
    if ('CslJoinRelay' -as [type]) {
        [CslJoinRelay]::Stop()
    }
}
