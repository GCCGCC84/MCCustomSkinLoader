package customskinloader.test.agent;

import java.lang.instrument.ClassFileTransformer;
import java.lang.instrument.Instrumentation;
import java.security.ProtectionDomain;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.concurrent.atomic.AtomicBoolean;

import org.objectweb.asm.ClassReader;
import org.objectweb.asm.ClassWriter;
import org.objectweb.asm.Opcodes;
import org.objectweb.asm.tree.AbstractInsnNode;
import org.objectweb.asm.tree.ClassNode;
import org.objectweb.asm.tree.InsnList;
import org.objectweb.asm.tree.InsnNode;
import org.objectweb.asm.tree.JumpInsnNode;
import org.objectweb.asm.tree.LdcInsnNode;
import org.objectweb.asm.tree.MethodNode;
import org.objectweb.asm.tree.TryCatchBlockNode;

/**
 * Test-only java agent carrying the workarounds for game-test failures that are caused by the
 * environment (Minecraft version, mod loader, headless GL) rather than by CustomSkinLoader, so the
 * game-test jobs keep testing the mod instead of the environment.
 *
 * <p>Launch it as {@code -javaagent:CustomSkinLoader-Test-1.0.0.jar=<workaround>[,<workaround>...]}.
 * JPLIS splits the argument at the first {@code '='}; writing {@code ':'} instead makes the JVM look
 * for a file named {@code "<jar>:<workaround>"} and the client dies before {@code main()} with
 * "Error opening zip file or JAR manifest missing", which is why Prepare-TestVersion.ps1 validates
 * the generated arguments.
 *
 * <p>Workaround ids match the JvmArgs of {@code .github/scripts/ExternalArgs.psd1}. Each one is
 * verified by the CI game-test jobs of the combos its entry applies to. The agent always states what
 * it did to stdout: which workarounds were requested, whether each patch matched, and whether the
 * patched class was written back, so a failing job shows whether the workaround was in effect.
 */
public final class Agent implements Opcodes {
    /**
     * Tells Minecraft's class apart from the thousands of other classes without hardcoding a name:
     * the constructor loads the window icon from this resource in every version the game tests patch,
     * and the string survives both remapping and deobfuscation. Mapping names cannot be used here,
     * because the same class is 'dvv' in an obfuscated jar, 'net.minecraft.client.Minecraft' on
     * Mojmap/SRG clients and an intermediary name on Fabric/Quilt that is not even stable across
     * versions (1.14.1 uses net.minecraft.class_355 where 1.15.2 uses net.minecraft.class_310).
     * Nothing in this agent patches the icon itself.
     */
    private static final String GAME_MARKER = "icons/icon_16x16.png";

    /**
     * Upper bound for the block deferJoin relocates. The vanilla constructors of 1.14-1.19 move
     * between 26 and 44 instructions; anything larger means the heuristic anchored on the wrong
     * block.
     */
    private static final int MAX_MOVED_INSTRUCTIONS = 64;

    /**
     * Forge ModLauncher network classes (1.13.2-1.14.3). The login handshake resolves them lazily
     * while the client is already ticking, which races the class loader.
     */
    private static final String[] FORGE_NETWORK_CLASSES = {
        "net.minecraftforge.fml.network.FMLNetworkConstants",
        "net.minecraftforge.fml.network.NetworkInitialization",
        "net.minecraftforge.fml.network.NetworkRegistry",
        "net.minecraftforge.fml.network.NetworkRegistry$ChannelBuilder",
        "net.minecraftforge.fml.network.NetworkRegistry$LoginPayload",
        "net.minecraftforge.fml.network.NetworkInstance",
        "net.minecraftforge.fml.network.NetworkDirection",
        "net.minecraftforge.fml.network.NetworkEvent",
        "net.minecraftforge.fml.network.NetworkEvent$Context",
        "net.minecraftforge.fml.network.NetworkEvent$LoginPayloadEvent",
        "net.minecraftforge.fml.network.NetworkEvent$ClientCustomPayloadEvent",
        "net.minecraftforge.fml.network.NetworkEvent$ServerCustomPayloadEvent",
        "net.minecraftforge.fml.network.NetworkEvent$ClientCustomPayloadLoginEvent",
        "net.minecraftforge.fml.network.NetworkEvent$ServerCustomPayloadLoginEvent",
        "net.minecraftforge.fml.network.NetworkEvent$GatherLoginPayloadsEvent",
        "net.minecraftforge.fml.network.simple.SimpleChannel",
        "net.minecraftforge.fml.network.simple.SimpleChannel$MessageBuilder",
        "net.minecraftforge.fml.network.simple.IndexedMessageCodec",
        "net.minecraftforge.fml.network.simple.IndexedMessageCodec$MessageHandler",
        "net.minecraftforge.fml.network.FMLHandshakeHandler",
        "net.minecraftforge.fml.network.FMLLoginWrapper",
        "net.minecraftforge.fml.network.FMLHandshakeMessages",
        "net.minecraftforge.fml.network.FMLHandshakeMessages$C2SAcknowledge",
        "net.minecraftforge.fml.network.FMLHandshakeMessages$LoginIndexedMessage",
        "net.minecraftforge.fml.network.FMLHandshakeMessages$S2CModList",
        "net.minecraftforge.fml.network.FMLHandshakeMessages$C2SModListReply",
        "net.minecraftforge.fml.network.FMLHandshakeMessages$S2CRegistry",
        "net.minecraftforge.fml.network.FMLHandshakeMessages$S2CConfigData",
        "net.minecraftforge.fml.network.FMLPlayMessages",
        "net.minecraftforge.fml.network.FMLPlayMessages$OpenContainer",
        "net.minecraftforge.fml.network.FMLPlayMessages$SpawnEntity",
        "net.minecraftforge.fml.network.event.EventNetworkChannel",
        "net.minecraftforge.fml.network.ConnectionType",
        "net.minecraftforge.fml.network.ICustomPacket",
        "net.minecraftforge.fml.network.PacketDispatcher",
        "net.minecraftforge.fml.util.ThreeConsumer"
    };

    private interface Patch {
        /** Returns true when the class was changed and has to be redefined. */
        boolean apply(ClassNode classNode);
    }

    private static final List<String> KNOWN_WORKAROUNDS =
            Arrays.asList("allowMultiplayer", "deferJoin", "preloadForgeNetwork");

    private Agent() {
    }

    public static void premain(String agentArgs, Instrumentation instrumentation) {
        List<String> requested = parseArguments(agentArgs);
        log("requested workarounds: " + requested);
        for (String workaround : requested) {
            if (!KNOWN_WORKAROUNDS.contains(workaround)) {
                throw new IllegalArgumentException("unknown workaround '" + workaround
                        + "', known workarounds: " + KNOWN_WORKAROUNDS);
            }
        }
        // Fixed application order instead of argument order: allowMultiplayer edits the permission
        // branch in front of the address check, which deferJoin then relocates behind it.
        if (requested.contains("allowMultiplayer")) {
            installGameTransformer(instrumentation, "allowMultiplayer", Agent::allowMultiplayer);
        }
        if (requested.contains("deferJoin")) {
            installGameTransformer(instrumentation, "deferJoin", Agent::deferJoin);
        }
        if (requested.contains("preloadForgeNetwork")) {
            installPreloadTrigger(instrumentation);
        }
    }

    private static List<String> parseArguments(String agentArgs) {
        List<String> workarounds = new ArrayList<String>();
        if (agentArgs == null) {
            return workarounds;
        }
        for (String argument : agentArgs.split(",")) {
            String workaround = argument.trim();
            if (!workaround.isEmpty()) {
                workarounds.add(workaround);
            }
        }
        return workarounds;
    }

    private static void log(String message) {
        System.out.println("[agent] " + message);
    }

    /**
     * Registers a patch for the class that carries {@link #GAME_MARKER}. The marker is searched in the
     * raw class file, so the ASM round trip only happens for the handful of classes that mention it.
     */
    private static void installGameTransformer(Instrumentation instrumentation, final String workaround, final Patch patch) {
        instrumentation.addTransformer(new ClassFileTransformer() {
            @Override
            public byte[] transform(ClassLoader loader, String className, Class<?> classBeingRedefined, ProtectionDomain protectionDomain, byte[] classfileBuffer) {
                if (className == null || !containsGameMarker(classfileBuffer)) {
                    return null;
                }
                try {
                    ClassReader classReader = new ClassReader(classfileBuffer);
                    ClassNode classNode = new ClassNode();
                    classReader.accept(classNode, ClassReader.EXPAND_FRAMES);
                    if (!patch.apply(classNode)) {
                        log(workaround + ": " + className + " left unchanged");
                        return null;
                    }
                    ClassWriter classWriter = new ClassWriter(classReader, ClassWriter.COMPUTE_MAXS);
                    classNode.accept(classWriter);
                    log(workaround + ": patched " + className);
                    return classWriter.toByteArray();
                } catch (Throwable throwable) {
                    // Never let the agent turn a workaround into its own failure: step aside, the class
                    // stays as it is and the combo fails with its original symptom if the workaround
                    // was needed.
                    log(workaround + ": " + className + " left unchanged after " + throwable);
                    return null;
                }
            }
        });
    }

    private static boolean containsGameMarker(byte[] classfileBuffer) {
        byte[] marker = GAME_MARKER.getBytes(java.nio.charset.StandardCharsets.UTF_8);
        nextCandidate:
        for (int start = 0; start + marker.length <= classfileBuffer.length; start++) {
            for (int offset = 0; offset < marker.length; offset++) {
                if (classfileBuffer[start + offset] != marker[offset]) {
                    continue nextCandidate;
                }
            }
            return true;
        }
        return false;
    }

    /**
     * Drops the multiplayer permission gate in front of the server address. 1.16.4 introduced
     * {@code if (allowsMultiplayer() && serverAddress != null)} in Minecraft's constructor, and
     * allowsMultiplayer() asks authlib's SocialInteractionsService, which answers false for the
     * throw-away session the game tests use. The client then silently drops the address and stays on
     * the title screen: no connect attempt, no log line, no crash, no screenshot. The patch replaces
     * that conditional branch with a POP, so only this constructor's decision changes and the rest of
     * the client (Multiplayer button, chat warning) keeps its behaviour.
     */
    private static boolean allowMultiplayer(ClassNode classNode) {
        MethodNode constructor = findGameConstructor(classNode);
        if (constructor == null) {
            log("allowMultiplayer: no constructor loads " + GAME_MARKER);
            return false;
        }
        // The gate and the "serverData.address == null" test branch to the same label, i.e.
        // "if (!allowsMultiplayer() || address == null) skip the address". Only the pair is
        // unambiguous, so look for an IFNULL with a matching IFEQ right in front of it.
        InsnList instructions = constructor.instructions;
        for (AbstractInsnNode current = instructions.getLast(); current != null; current = current.getPrevious()) {
            if (current.getOpcode() != IFNULL) {
                continue;
            }
            AbstractInsnNode skip = ((JumpInsnNode) current).label;
            AbstractInsnNode candidate = current.getPrevious();
            for (int distance = 0; candidate != null && distance < 12; distance++, candidate = candidate.getPrevious()) {
                if (candidate.getOpcode() == IFEQ && ((JumpInsnNode) candidate).label == skip) {
                    instructions.set(candidate, new InsnNode(POP));
                    log("allowMultiplayer: dropped the multiplayer gate in " + constructor.name);
                    return true;
                }
            }
        }
        log("allowMultiplayer: no multiplayer gate in front of an address check in " + constructor.name);
        return false;
    }

    /**
     * Defers the automatic join of the server address: the client connects while the first resource
     * reload is still running, so it renders the world before the block atlas and the shaders exist
     * (1.15.1 raised ReportedException "Rendering overlay" from ConnectingScreen.&lt;init&gt;, 1.18 hit
     * an NPE in ShaderInstance.getUniform() and a missing textures/atlas/blocks.png).
     *
     * <p>The join lives at the end of Minecraft's constructor as
     * {@code setScreen(serverAddress != null ? new ConnectScreen(new TitleScreen(), this, host, port)
     * : new TitleScreen(true))}. The patch moves the address-dependent block behind the rest of the
     * constructor, so the connecting screen is created after the loading overlay has been installed
     * instead of before it.
     */
    private static boolean deferJoin(ClassNode classNode) {
        MethodNode constructor = findGameConstructor(classNode);
        if (constructor == null) {
            log("deferJoin: no constructor loads " + GAME_MARKER);
            return false;
        }

        InsnList instructions = constructor.instructions;
        AbstractInsnNode gotoNode = findLast(instructions, GOTO, null);
        JumpInsnNode addressCheck = findAddressCheck(instructions);
        AbstractInsnNode addressNode = addressCheck == null ? null : addressCheck.getPrevious();
        AbstractInsnNode returnNode = findLast(instructions, RETURN, null);
        if (gotoNode == null || addressNode == null || returnNode == null) {
            log("deferJoin: no address check followed by a GOTO in " + constructor.name);
            return false;
        }

        AbstractInsnNode stop = ((JumpInsnNode) gotoNode).label.getNext();
        String rejection = rejectMovedRange(constructor, addressNode, stop);
        if (rejection != null) {
            log("deferJoin: " + rejection + " in " + constructor.name + ", left unchanged");
            return false;
        }

        InsnList moved = new InsnList();
        for (AbstractInsnNode current = addressNode; current != null && current != stop; ) {
            AbstractInsnNode next = current.getNext();
            instructions.remove(current);
            moved.add(current);
            current = next;
        }
        int movedCount = moved.size();
        // insertBefore(InsnList) hands the instructions over to the target list, so count first.
        instructions.insertBefore(returnNode, moved);
        log("deferJoin: moved " + movedCount + " instruction(s) behind the rest of " + constructor.name);
        return true;
    }

    /**
     * Tells whether moving [start, stop) would produce a class the verifier accepts, and returns the
     * reason when it would not. The vanilla constructor of 1.15/1.16 moves 26 instructions, but on
     * 1.14 the same pattern matched 778 instructions and the client died with "VerifyError: Bad local
     * variable type": a block that carries a screen construction, stays within these bounds and stays
     * out of every exception handler and branch target is safe, anything else is left alone.
     */
    private static String rejectMovedRange(MethodNode constructor, AbstractInsnNode start, AbstractInsnNode stop) {
        int size = 0;
        boolean buildsScreen = false;
        for (AbstractInsnNode current = start; current != null && current != stop; current = current.getNext()) {
            size++;
            if (current.getOpcode() == NEW) {
                buildsScreen = true;
            }
            if (current instanceof JumpInsnNode && !within(((JumpInsnNode) current).label, start, stop)) {
                return "the block branches out of itself";
            }
        }
        if (!buildsScreen) {
            return "no screen construction after the address check";
        }
        if (size > MAX_MOVED_INSTRUCTIONS) {
            return "the block has " + size + " instructions (limit " + MAX_MOVED_INSTRUCTIONS + ")";
        }
        for (AbstractInsnNode current = constructor.instructions.getFirst(); current != null; current = current.getNext()) {
            if (current instanceof JumpInsnNode && !within(current, start, stop) && within(((JumpInsnNode) current).label, start, stop)) {
                return "code outside the block branches into it";
            }
        }
        for (Object block : constructor.tryCatchBlocks) {
            TryCatchBlockNode tryCatch = (TryCatchBlockNode) block;
            if (overlaps(tryCatch.start, start, stop) || overlaps(tryCatch.end, start, stop) || overlaps(tryCatch.handler, start, stop)) {
                if (!(within(tryCatch.start, start, stop) && within(tryCatch.end, start, stop) && within(tryCatch.handler, start, stop))) {
                    return "the block cuts through an exception handler";
                }
            }
        }
        return null;
    }

    private static boolean within(AbstractInsnNode node, AbstractInsnNode start, AbstractInsnNode stop) {
        for (AbstractInsnNode current = start; current != null && current != stop; current = current.getNext()) {
            if (current == node) {
                return true;
            }
        }
        return false;
    }

    /** True when the node is one of the range bounds or sits between them. */
    private static boolean overlaps(AbstractInsnNode node, AbstractInsnNode start, AbstractInsnNode stop) {
        return within(node, start, stop) || node == stop;
    }

    /**
     * Preloads the Forge network classes on the game class loader. The trigger is the transformation
     * of the game class itself: that is the earliest point at which the loader is known, and the
     * loading runs on its own thread so the class loader is not re-entered from within a
     * transformation.
     */
    private static void installPreloadTrigger(Instrumentation instrumentation) {
        final AtomicBoolean triggered = new AtomicBoolean(false);
        instrumentation.addTransformer(new ClassFileTransformer() {
            @Override
            public byte[] transform(ClassLoader loader, String className, Class<?> classBeingRedefined, ProtectionDomain protectionDomain, byte[] classfileBuffer) {
                if (className == null || loader == null || !containsGameMarker(classfileBuffer) || !triggered.compareAndSet(false, true)) {
                    return null;
                }
                log("preloadForgeNetwork: game class loader seen on " + className);
                Thread preload = new Thread(new Runnable() {
                    @Override
                    public void run() {
                        int loaded = 0;
                        for (String networkClass : FORGE_NETWORK_CLASSES) {
                            try {
                                Class.forName(networkClass, false, loader);
                                loaded++;
                            } catch (Throwable ignored) {
                                // Not present on this loader or this Minecraft version.
                            }
                        }
                        log("preloadForgeNetwork: loaded " + loaded + " of " + FORGE_NETWORK_CLASSES.length + " class(es)");
                    }
                }, "CustomSkinLoader-Test-Preload");
                preload.setDaemon(true);
                preload.start();
                return null;
            }
        });
    }

    private static MethodNode findGameConstructor(ClassNode classNode) {
        for (MethodNode methodNode : classNode.methods) {
            if (loadsIconResource(methodNode)) {
                return methodNode;
            }
        }
        return null;
    }

    /** Finds the "if (serverAddress != null)" test: the last ALOAD followed by an IFNULL. */
    private static JumpInsnNode findAddressCheck(InsnList instructions) {
        for (AbstractInsnNode current = instructions.getLast(); current != null; current = current.getPrevious()) {
            if (current.getOpcode() != IFNULL) {
                continue;
            }
            AbstractInsnNode previous = current.getPrevious();
            if (previous != null && previous.getOpcode() == ALOAD) {
                return (JumpInsnNode) current;
            }
        }
        return null;
    }

    private static AbstractInsnNode findLast(InsnList instructions, int opcode, AbstractInsnNode before) {
        for (AbstractInsnNode current = before == null ? instructions.getLast() : before.getPrevious(); current != null; current = current.getPrevious()) {
            if (current.getOpcode() == opcode) {
                return current;
            }
        }
        return null;
    }

    private static boolean loadsIconResource(MethodNode methodNode) {
        for (AbstractInsnNode current = methodNode.instructions.getFirst(); current != null; current = current.getNext()) {
            if (current instanceof LdcInsnNode && GAME_MARKER.equals(((LdcInsnNode) current).cst)) {
                return true;
            }
        }
        return false;
    }
}
