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
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Threading;

public static class CslJoinRelay
{
    private sealed class RelayState
    {
        public readonly MemoryStream Held = new MemoryStream();
        public readonly object Gate = new object();
        public NetworkStream To;
    }

    private static TcpListener listener;
    private static Thread acceptThread;
    private static volatile bool running;
    private static volatile bool released;
    private static int heldFrames;
    private static long heldBytes;
    private static string lastStatus = "idle";
    private static readonly object statusGate = new object();

    public static void Start(int listenPort, int upstreamPort, int threshold)
    {
        Stop();
        released = false;
        heldFrames = 0;
        heldBytes = 0;
        listener = new TcpListener(IPAddress.Loopback, listenPort);
        listener.Start();
        running = true;
        acceptThread = new Thread(() => AcceptLoop(upstreamPort, threshold));
        acceptThread.IsBackground = true;
        acceptThread.Start();
        SetStatus("listening " + listenPort + " -> " + upstreamPort);
    }

    public static void Release()
    {
        released = true;
        SetStatus("released heldFrames=" + Interlocked.CompareExchange(ref heldFrames, 0, 0)
            + " heldBytes=" + Interlocked.Read(ref heldBytes));
    }

    public static string GetStatus()
    {
        lock (statusGate) { return lastStatus; }
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

        var send = new Thread(() => PumpRaw(client.GetStream(), upstream.GetStream()));
        send.IsBackground = true;
        send.Start();
        var receive = new Thread(() => PumpFramed(upstream.GetStream(), state, threshold));
        receive.IsBackground = true;
        receive.Start();
        var flush = new Thread(() => FlushLoop(state));
        flush.IsBackground = true;
        flush.Start();
    }

    private static void PumpRaw(NetworkStream from, NetworkStream to)
    {
        var buffer = new byte[65536];
        try
        {
            int read;
            while ((read = from.Read(buffer, 0, buffer.Length)) > 0)
            {
                to.Write(buffer, 0, read);
                to.Flush();
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

                lock (state.Gate)
                {
                    if (!released && length > threshold)
                    {
                        WriteVarInt(state.Held, length);
                        state.Held.Write(frame, 0, length);
                        Interlocked.Increment(ref heldFrames);
                        Interlocked.Add(ref heldBytes, length);
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
            }
            catch { return; }
            Thread.Sleep(200);
        }
    }

    private static void FlushHeld(RelayState state)
    {
        if (state.Held.Length == 0) return;
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

    # Forge patches Minecraft to open the initial screen after the first
    # resource reload (MC-145102), Fabric/Quilt do not. The early connect
    # ordering itself only exists in 1.14-1.16.5; 1.17.0 crashes before the
    # connection is even attempted (MC-228828), and 1.17.1+ is fixed.
    if ($Loader -in @('forge', 'neoforge')) {
        return $false
    }
    return ($McVersion -match '^1\.(14|15|16)(\.\d+)?$')
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

function Start-JoinRelay {
    param(
        [Parameter(Mandatory)][int]$ListenPort,
        [Parameter(Mandatory)][int]$UpstreamPort,
        [int]$FrameThreshold = 64
    )

    Initialize-JoinRelay
    [CslJoinRelay]::Start($ListenPort, $UpstreamPort, $FrameThreshold)
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

function Stop-JoinRelay {
    if ('CslJoinRelay' -as [type]) {
        [CslJoinRelay]::Stop()
    }
}
