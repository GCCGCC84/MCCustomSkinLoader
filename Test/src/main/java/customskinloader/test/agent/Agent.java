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

    private Agent() {
    }

    public static void premain(String agentArgs, Instrumentation instrumentation) {
        final Set<String> targetClasses = parseTargetClasses(agentArgs);
        instrumentation.addTransformer(new ClassFileTransformer() {
            @Override
            public byte[] transform(ClassLoader loader, String className, Class<?> classBeingRedefined, ProtectionDomain protectionDomain, byte[] classfileBuffer) {
                if (className == null || !targetClasses.contains(className)) {
                    return null;
                }
                return patchClass(classfileBuffer);
            }
        });
    }

    private static Set<String> parseTargetClasses(String agentArgs) {
        Set<String> targetClasses = new LinkedHashSet<String>();
        if (agentArgs != null) {
            for (String argument : agentArgs.split(",")) {
                String className = argument.trim();
                int separator = className.indexOf('=');
                if (separator >= 0) {
                    className = className.substring(separator + 1).trim();
                }
                if (!className.isEmpty()) {
                    targetClasses.add(className.replace('.', '/'));
                }
            }
        }
        if (targetClasses.isEmpty()) {
            for (String className : DEFAULT_TARGET_CLASSES) {
                targetClasses.add(className);
            }
        }
        return targetClasses;
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
