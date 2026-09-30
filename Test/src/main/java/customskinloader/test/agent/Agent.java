package customskinloader.test.agent;

import java.lang.instrument.ClassFileTransformer;
import java.lang.instrument.Instrumentation;
import java.security.ProtectionDomain;
import java.util.LinkedHashSet;
import java.util.Set;

import org.objectweb.asm.ClassReader;
import org.objectweb.asm.ClassWriter;
import org.objectweb.asm.Opcodes;
import org.objectweb.asm.tree.AbstractInsnNode;
import org.objectweb.asm.tree.ClassNode;
import org.objectweb.asm.tree.InsnList;
import org.objectweb.asm.tree.InsnNode;
import org.objectweb.asm.tree.JumpInsnNode;
import org.objectweb.asm.tree.LabelNode;
import org.objectweb.asm.tree.LdcInsnNode;
import org.objectweb.asm.tree.MethodNode;
import org.objectweb.asm.tree.VarInsnNode;

public final class Agent implements Opcodes {
    private static final String[] DEFAULT_TARGET_CLASSES = {"net.minecraft.class_310", "net.minecraft.client.Minecraft"};
    private static final String[] GAME_CLASSES = {"net.minecraft.client.Minecraft", "net.minecraft.class_310"};
    private static final String[] PRELOAD_CLASSES = {
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

    private Agent() {
    }

    public static void premain(String agentArgs, Instrumentation instrumentation) {
        Set<String> targetClasses = new LinkedHashSet<String>();
        boolean migrateIcon = false;
        boolean preloadForgeNetwork = false;
        if (agentArgs != null) {
            for (String argument : agentArgs.split(",")) {
                String token = argument.trim();
                int separator = token.indexOf('=');
                String name = separator >= 0 ? token.substring(0, separator).trim() : token;
                String value = separator >= 0 ? token.substring(separator + 1).trim() : "";
                if ("icon".equals(name)) {
                    migrateIcon = true;
                    if (!value.isEmpty()) {
                        targetClasses.add(value.replace('.', '/'));
                    }
                } else if ("preload".equals(name) && value.isEmpty()) {
                    preloadForgeNetwork = true;
                }
            }
        }
        if (migrateIcon) {
            if (targetClasses.isEmpty()) {
                for (String className : DEFAULT_TARGET_CLASSES) {
                    targetClasses.add(className.replace('.', '/'));
                }
            }
            final Set<String> classes = targetClasses;
            instrumentation.addTransformer(new ClassFileTransformer() {
                @Override
                public byte[] transform(ClassLoader loader, String className, Class<?> classBeingRedefined, ProtectionDomain protectionDomain, byte[] classfileBuffer) {
                    if (className == null || !classes.contains(className)) {
                        return null;
                    }
                    return patchClass(classfileBuffer);
                }
            });
        }
        if (preloadForgeNetwork) {
            Thread preloadThread = new Thread(new Runnable() {
                @Override
                public void run() {
                    ClassLoader loader = null;
                    while (loader == null) {
                        for (Thread thread : Thread.getAllStackTraces().keySet()) {
                            ClassLoader candidate = thread.getContextClassLoader();
                            if (candidate == null) {
                                continue;
                            }
                            for (String gameClass : GAME_CLASSES) {
                                try {
                                    Class.forName(gameClass, false, candidate);
                                    loader = candidate;
                                    break;
                                } catch (Throwable ignored) {
                                }
                            }
                            if (loader != null) {
                                break;
                            }
                        }
                        if (loader == null) {
                            try {
                                Thread.sleep(100L);
                            } catch (InterruptedException e) {
                                return;
                            }
                        }
                    }
                    for (String className : PRELOAD_CLASSES) {
                        try {
                            Class.forName(className, false, loader);
                        } catch (Throwable ignored) {
                        }
                    }
                }
            }, "CustomSkinLoader-Test-Preload");
            preloadThread.setDaemon(true);
            preloadThread.start();
        }
    }

    static byte[] patchClass(byte[] classfileBuffer) {
        ClassReader classReader = new ClassReader(classfileBuffer);
        ClassNode classNode = new ClassNode();
        classReader.accept(classNode, ClassReader.EXPAND_FRAMES);

        boolean modified = false;
        for (MethodNode methodNode : classNode.methods) {
            modified |= migrateIconBlock(methodNode);
        }
        if (!modified) {
            return null;
        }

        ClassWriter classWriter = new ClassWriter(classReader, ClassWriter.COMPUTE_MAXS);
        classNode.accept(classWriter);
        return classWriter.toByteArray();
    }

    private static boolean migrateIconBlock(MethodNode methodNode) {
        if (!containsTargetIcon(methodNode)) {
            return false;
        }

        JumpInsnNode gotoNode = null;
        for (AbstractInsnNode current = methodNode.instructions.getLast(); current != null; current = current.getPrevious()) {
            if (current.getOpcode() == GOTO) {
                gotoNode = (JumpInsnNode) current;
                break;
            }
        }
        if (gotoNode == null) {
            return false;
        }
        LabelNode gotoLabel = gotoNode.label;

        JumpInsnNode ifNullNode = null;
        for (AbstractInsnNode current = gotoNode.getPrevious(); current != null; current = current.getPrevious()) {
            if (current.getOpcode() == IFNULL) {
                ifNullNode = (JumpInsnNode) current;
                break;
            }
        }
        if (ifNullNode == null) {
            return false;
        }

        VarInsnNode aloadNode = null;
        for (AbstractInsnNode current = ifNullNode.getPrevious(); current != null; current = current.getPrevious()) {
            if (current.getOpcode() == ALOAD) {
                aloadNode = (VarInsnNode) current;
                break;
            }
        }
        if (aloadNode == null) {
            return false;
        }

        InsnNode returnNode = null;
        for (AbstractInsnNode current = methodNode.instructions.getLast(); current != null; current = current.getPrevious()) {
            if (current.getOpcode() == RETURN) {
                returnNode = (InsnNode) current;
                break;
            }
        }
        if (returnNode == null) {
            return false;
        }

        AbstractInsnNode stop = gotoLabel.getNext();

        InsnList moved = new InsnList();
        AbstractInsnNode current = aloadNode;
        while (current != null && current != stop) {
            AbstractInsnNode next = current.getNext();
            methodNode.instructions.remove(current);
            moved.add(current);
            current = next;
        }
        if (moved.size() == 0) {
            return false;
        }
        methodNode.instructions.insertBefore(returnNode, moved);
        return true;
    }

    private static boolean containsTargetIcon(MethodNode methodNode) {
        for (AbstractInsnNode current = methodNode.instructions.getFirst(); current != null; current = current.getNext()) {
            if (current instanceof LdcInsnNode && "icons/icon_16x16.png".equals(((LdcInsnNode) current).cst)) {
                return true;
            }
        }
        return false;
    }

    private static boolean isBefore(AbstractInsnNode start, AbstractInsnNode target) {
        for (AbstractInsnNode current = start.getNext(); current != null; current = current.getNext()) {
            if (current == target) {
                return true;
            }
        }
        return false;
    }
}
