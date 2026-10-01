package customskinloader.test.agent;

import java.lang.instrument.ClassFileTransformer;
import java.lang.instrument.Instrumentation;
import java.security.ProtectionDomain;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;
import java.util.concurrent.atomic.AtomicBoolean;

import org.objectweb.asm.ClassReader;
import org.objectweb.asm.ClassWriter;
import org.objectweb.asm.Opcodes;
import org.objectweb.asm.tree.AbstractInsnNode;
import org.objectweb.asm.tree.ClassNode;
import org.objectweb.asm.tree.InsnList;
import org.objectweb.asm.tree.JumpInsnNode;
import org.objectweb.asm.tree.LdcInsnNode;
import org.objectweb.asm.tree.MethodNode;

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
    /** Minecraft in the mapping namespaces the game tests run under (Mojmap/SRG and intermediary). */
    private static final String[] GAME_CLASSES = {"net.minecraft.client.Minecraft", "net.minecraft.class_310"};

    /**
     * Locates Minecraft's constructor: the only method of the class that loads the window icon
     * resource. Nothing in this agent patches the icon itself, the string is only used to tell
     * Minecraft apart from other classes in every mapping namespace.
     */
    private static final String ICON_RESOURCE = "icons/icon_16x16.png";

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

    private Agent() {
    }

    public static void premain(String agentArgs, Instrumentation instrumentation) {
        List<String> workarounds = parseArguments(agentArgs);
        log("requested workarounds: " + workarounds);
        for (String workaround : workarounds) {
            if ("deferJoin".equals(workaround)) {
                installTransformer(instrumentation, workaround, GAME_CLASSES, Agent::deferJoin);
            } else if ("preloadForgeNetwork".equals(workaround)) {
                installPreloadTrigger(instrumentation);
            } else {
                throw new IllegalArgumentException("unknown workaround '" + workaround
                        + "', known workarounds: deferJoin, preloadForgeNetwork");
            }
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

    private static void installTransformer(Instrumentation instrumentation, final String workaround, String[] targetClasses, final Patch patch) {
        final Set<String> targets = new LinkedHashSet<String>(Arrays.asList(targetClasses));
        instrumentation.addTransformer(new ClassFileTransformer() {
            @Override
            public byte[] transform(ClassLoader loader, String className, Class<?> classBeingRedefined, ProtectionDomain protectionDomain, byte[] classfileBuffer) {
                if (className == null || !targets.contains(className)) {
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
        MethodNode constructor = null;
        for (MethodNode methodNode : classNode.methods) {
            if (containsIconResource(methodNode)) {
                constructor = methodNode;
                break;
            }
        }
        if (constructor == null) {
            log("deferJoin: no constructor loads " + ICON_RESOURCE);
            return false;
        }

        InsnList instructions = constructor.instructions;
        AbstractInsnNode gotoNode = findLast(instructions, GOTO, null);
        AbstractInsnNode ifNullNode = findLast(instructions, IFNULL, gotoNode);
        AbstractInsnNode addressNode = findLast(instructions, ALOAD, ifNullNode);
        AbstractInsnNode returnNode = findLast(instructions, RETURN, null);
        if (addressNode == null || returnNode == null) {
            log("deferJoin: no address check followed by a GOTO in " + constructor.name);
            return false;
        }

        // Leave the class alone unless the block really builds a screen: moving an unrelated block
        // would be worse than not applying the workaround at all.
        AbstractInsnNode stop = ((JumpInsnNode) gotoNode).label.getNext();
        boolean buildsScreen = false;
        for (AbstractInsnNode current = addressNode; current != null && current != stop; current = current.getNext()) {
            if (current.getOpcode() == NEW) {
                buildsScreen = true;
                break;
            }
        }
        if (!buildsScreen) {
            log("deferJoin: no screen construction after the address check in " + constructor.name);
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
        if (movedCount == 0) {
            log("deferJoin: nothing to move in " + constructor.name);
            return false;
        }
        // insertBefore(InsnList) hands the instructions over to the target list, so count first.
        instructions.insertBefore(returnNode, moved);
        log("deferJoin: moved " + movedCount + " instruction(s) behind the rest of " + constructor.name);
        return true;
    }

    /**
     * Preloads the Forge network classes on the game class loader. The trigger is the transformation
     * of the game class itself: that is the earliest point at which the loader is known, and the
     * loading runs on its own thread so the class loader is not re-entered from within a
     * transformation.
     */
    private static void installPreloadTrigger(Instrumentation instrumentation) {
        final Set<String> targets = new LinkedHashSet<String>(Arrays.asList(GAME_CLASSES));
        final AtomicBoolean triggered = new AtomicBoolean(false);
        instrumentation.addTransformer(new ClassFileTransformer() {
            @Override
            public byte[] transform(ClassLoader loader, String className, Class<?> classBeingRedefined, ProtectionDomain protectionDomain, byte[] classfileBuffer) {
                if (className == null || loader == null || !targets.contains(className) || !triggered.compareAndSet(false, true)) {
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

    private static AbstractInsnNode findLast(InsnList instructions, int opcode, AbstractInsnNode before) {
        for (AbstractInsnNode current = before == null ? instructions.getLast() : before.getPrevious(); current != null; current = current.getPrevious()) {
            if (current.getOpcode() == opcode) {
                return current;
            }
        }
        return null;
    }

    private static boolean containsIconResource(MethodNode methodNode) {
        for (AbstractInsnNode current = methodNode.instructions.getFirst(); current != null; current = current.getNext()) {
            if (current instanceof LdcInsnNode && ICON_RESOURCE.equals(((LdcInsnNode) current).cst)) {
                return true;
            }
        }
        return false;
    }
}
