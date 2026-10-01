package customskinloader.test.agent;

import java.lang.instrument.ClassFileTransformer;
import java.lang.instrument.Instrumentation;
import java.security.ProtectionDomain;
import java.util.ArrayList;
import java.util.Collections;
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
import org.objectweb.asm.Type;
import org.objectweb.asm.tree.FrameNode;
import org.objectweb.asm.tree.MethodInsnNode;
import org.objectweb.asm.tree.VarInsnNode;
import org.objectweb.asm.tree.LabelNode;
import org.objectweb.asm.tree.LineNumberNode;
import java.util.LinkedHashMap;
import java.util.Map;
import org.objectweb.asm.tree.IntInsnNode;
import org.objectweb.asm.tree.TypeInsnNode;
import org.objectweb.asm.tree.FieldInsnNode;
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

    /** Method the agent adds to the game class for the join; AgentBridge calls it reflectively. */
    private static final String JOIN_METHOD = "__cslDeferredJoin";

    /** Bridge class of the agent jar; only java.lang types cross this boundary. */
    private static final String BRIDGE_CLASS = "customskinloader/test/agent/AgentBridge";

    /**
     * Upper bound for the connect branch. The vanilla constructors keep it between 6 and 69
     * instructions (1.14 builds the parent screen, the address and its own temporaries inside the
     * branch); anything larger means the structural search anchored on the wrong part of the
     * constructor.
     */
    private static final int MAX_CONNECT_BRANCH_INSTRUCTIONS = 96;

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
     * Defers the automatic join of the server address until the first resource reload has finished.
     *
     * <p>The constructor of 1.14-1.19 contains {@code setScreen(serverAddress != null ?
     * new ConnectScreen(new TitleScreen(), this, host, port) : new TitleScreen(true))}, and the
     * connecting screen connects from its own constructor, so the client joins and renders the world
     * while the block atlas and the shaders are still being built (1.15.1 raised ReportedException
     * "Rendering overlay", 1.18 NPEs while tesselating a block, 1.14.1 the same with "Tesselating
     * block in world"). The patch:
     * <ul>
     *   <li>hands the address to {@link AgentBridge} and always takes the title screen branch,</li>
     *   <li>moves the connect branch verbatim into a new method of the game class, which
     *       {@link AgentBridge#onOverlayChanged} invokes reflectively,</li>
     *   <li>calls the bridge from the overlay setter, which runs exactly when the loading overlay is
     *       cleared, i.e. when the first resource reload is done.</li>
     * </ul>
     * Everything is found by shape and moved verbatim, so no mapping name is needed. The class is left
     * alone whenever a shape does not match, and the log states why.
     */
    private static boolean deferJoin(ClassNode classNode) {
        MethodNode constructor = findGameConstructor(classNode);
        if (constructor == null) {
            log("deferJoin: no constructor loads " + GAME_MARKER);
            return false;
        }
        InsnList instructions = constructor.instructions;
        JumpInsnNode addressCheck = findAddressCheck(instructions);
        VarInsnNode addressNode = addressCheck == null ? null : (VarInsnNode) addressCheck.getPrevious();
        if (addressNode == null || addressCheck.getNext() == null) {
            log("deferJoin: no server address check in " + constructor.name);
            return false;
        }
        // The branch starts behind the label, line number and frame entries of this position; they stay
        // in the constructor, where nothing depends on them any more once the body has moved.
        AbstractInsnNode connectStart = addressCheck.getNext();
        while (connectStart != null && (connectStart instanceof LabelNode || connectStart instanceof LineNumberNode || connectStart instanceof FrameNode)) {
            connectStart = connectStart.getNext();
        }
        AbstractInsnNode connectEnd = connectStart == null ? null : findNext(instructions, GOTO, connectStart, null);
        if (connectEnd == null) {
            log("deferJoin: the connect branch does not end with a branch in " + constructor.name);
            return false;
        }
        List<Integer> extraLocals = new ArrayList<Integer>();
        List<Integer> allForeignLocals = new ArrayList<Integer>();
        String rejection = rejectConnectBranch(constructor, connectStart, connectEnd, addressNode.var, extraLocals, allForeignLocals);
        if (rejection != null) {
            log("deferJoin: " + rejection + " in " + constructor.name + ", left unchanged");
            return false;
        }
        List<MethodInsnNode> setters = findSetters(constructor, classNode.name);
        if (setters.isEmpty()) {
            log("deferJoin: no screen or overlay setter in " + constructor.name + ", left unchanged");
            return false;
        }

        int hostLocal = addressNode.var;
        // 1.14 passes host and port inside an object local, so there may be no port local at all.
        AbstractInsnNode portNode = findNext(instructions, ILOAD, connectStart, connectEnd);
        int portLocal = portNode == null ? 0 : ((VarInsnNode) portNode).var;
        List<String> extraTypes = new ArrayList<String>();
        for (int local : extraLocals) {
            String type = findLocalType(connectStart, connectEnd, local);
            if (type == null) {
                log("deferJoin: cannot tell the type of local " + local + " in " + constructor.name + ", left unchanged");
                return false;
            }
            extraTypes.add(type);
        }

        // The connect branch becomes a method of its own: "this" stays local 0, the address and the
        // port move to the two parameter slots.
        MethodNode join = new MethodNode(ACC_PUBLIC, JOIN_METHOD, "(Ljava/lang/String;I[Ljava/lang/Object;)V", null, null);
        Map<Integer, Integer> movedSlots = new LinkedHashMap<Integer, Integer>();
        List<Object> joinLocals = new ArrayList<Object>();
        joinLocals.add(classNode.name);
        joinLocals.add("java/lang/String");
        joinLocals.add(INTEGER);
        joinLocals.add("[Ljava/lang/Object;");
        int nextSlot = 4;
        for (int index = 0; index < extraLocals.size(); index++) {
            movedSlots.put(extraLocals.get(index), nextSlot);
            join.instructions.add(new VarInsnNode(ALOAD, 3));
            join.instructions.add(intConstant(index));
            join.instructions.add(new InsnNode(AALOAD));
            join.instructions.add(new TypeInsnNode(CHECKCAST, extraTypes.get(index)));
            join.instructions.add(new VarInsnNode(ASTORE, nextSlot));
            joinLocals.add("java/lang/Object");
            nextSlot++;
        }
        for (int local : allForeignLocals) {
            if (movedSlots.containsKey(local)) {
                continue;
            }
            movedSlots.put(local, nextSlot);
            joinLocals.add(localType(connectStart, connectEnd, local));
            nextSlot++;
        }
        for (AbstractInsnNode current = connectStart; current != null && current != connectEnd; ) {
            AbstractInsnNode next = current.getNext();
            instructions.remove(current);
            if (current instanceof LineNumberNode) {
                // Only meaningful for the constructor's own stack traces.
                current = next;
                continue;
            }
            if (current instanceof VarInsnNode) {
                VarInsnNode variable = (VarInsnNode) current;
                if (variable.var == hostLocal) {
                    variable.var = 1;
                } else if (variable.var == portLocal) {
                    variable.var = 2;
                } else if (movedSlots.containsKey(variable.var)) {
                    variable.var = movedSlots.get(variable.var);
                } else {
                    variable.var = 0;
                }
            }
            if (current instanceof FrameNode) {
                // The moved code runs on "this, host, port" only; a stack map frame at one of its
                // internal jump targets has to say exactly that.
                FrameNode frame = (FrameNode) current;
                frame.type = F_NEW;
                frame.local = joinLocals;
                frame.stack = Collections.emptyList();
            }
            join.instructions.add(current);
            current = next;
        }
        join.instructions.add(new InsnNode(RETURN));
        classNode.methods.add(join);

        // Hand the address to the bridge and skip the connect branch: the client starts on the title
        // screen and the bridge joins as soon as the loading overlay is gone.
        InsnList handover = new InsnList();
        handover.add(new VarInsnNode(ALOAD, 0));
        handover.add(new VarInsnNode(ALOAD, hostLocal));
        handover.add(portNode == null ? intConstant(0) : new VarInsnNode(ILOAD, portLocal));
        handover.add(intConstant(extraLocals.size()));
        handover.add(new TypeInsnNode(ANEWARRAY, "java/lang/Object"));
        for (int index = 0; index < extraLocals.size(); index++) {
            handover.add(new InsnNode(DUP));
            handover.add(intConstant(index));
            handover.add(new VarInsnNode(ALOAD, extraLocals.get(index)));
            handover.add(new InsnNode(AASTORE));
        }
        handover.add(new MethodInsnNode(INVOKESTATIC, BRIDGE_CLASS, "deferJoin", "(Ljava/lang/Object;Ljava/lang/String;I[Ljava/lang/Object;)V", false));
        instructions.insertBefore(addressNode, handover);
        instructions.insertBefore(addressCheck, new InsnNode(POP));
        instructions.set(addressCheck, new JumpInsnNode(GOTO, addressCheck.label));
        instructions.remove(connectEnd);

        StringBuilder hooked = new StringBuilder();
        for (MethodInsnNode setter : setters) {
            MethodNode setterMethod = findMethod(classNode, setter.name, setter.desc);
            InsnList hook = new InsnList();
            hook.add(new VarInsnNode(ALOAD, 1));
            hook.add(new LdcInsnNode(setter.name + setter.desc));
            hook.add(new MethodInsnNode(INVOKESTATIC, BRIDGE_CLASS, "onSet", "(Ljava/lang/Object;Ljava/lang/String;)V", false));
            setterMethod.instructions.insert(hook);
            if (hooked.length() > 0) {
                hooked.append(", ");
            }
            hooked.append(setter.name).append(setter.desc);
        }

        log("deferJoin: connect branch moved to " + JOIN_METHOD + " (host local " + hostLocal
                + ", port local " + portLocal + "), join runs when the overlay is cleared (setters: " + hooked + ")");
        return true;
    }

    /**
     * Tells whether the connect branch can be moved into a method of its own, and returns the reason
     * when it cannot. The branch has to be a straight sequence that only reads the constructor's
     * "this", address and port, builds a screen and sets it: labels, frames, jumps or other locals
     * cannot be relocated without recomputing frames, and a branch that cuts through an exception
     * handler invalidates the handler table (1.14's constructor is such a case; its heuristic block
     * had 778 instructions and the client died with "VerifyError: Bad local variable type").
     */
    private static String rejectConnectBranch(MethodNode constructor, AbstractInsnNode start, AbstractInsnNode stop, int hostLocal,
            List<Integer> readableLocals, List<Integer> knownLocals) {
        int size = 0;
        int ports = 0;
        boolean acts = false;
        boolean usesContext = false;
        for (AbstractInsnNode current = start; current != null && current != stop; current = current.getNext()) {
            size++;
            int opcode = current.getOpcode();
            if (opcode == NEW || opcode == INVOKEVIRTUAL || opcode == INVOKESTATIC || opcode == INVOKESPECIAL) {
                acts = true;
            }
            if (opcode == ALOAD && ((VarInsnNode) current).var == hostLocal) {
                usesContext = true;
            }
            if (current instanceof JumpInsnNode && !between(((JumpInsnNode) current).label, start, stop)) {
                return "the connect branch jumps out of itself";
            }
            if (current instanceof FrameNode && !((FrameNode) current).stack.isEmpty()) {
                return "a frame inside the connect branch has a non-empty stack";
            }
            if (current instanceof VarInsnNode) {
                VarInsnNode variable = (VarInsnNode) current;
                if (opcode == ILOAD) {
                    ports++;
                } else if (variable.var != 0 && variable.var != hostLocal) {
                    boolean store = opcode == ASTORE || opcode == ISTORE || opcode == LSTORE
                            || opcode == FSTORE || opcode == DSTORE;
                    if (!store && !readableLocals.contains(variable.var)) {
                        // Only object locals can travel through the bridge; the branches that need this
                        // read the game configuration or an address object computed earlier.
                        if (opcode != ALOAD) {
                            return "the connect branch reads local " + variable.var + " (opcode " + opcode + ")";
                        }
                        readableLocals.add(variable.var);
                    }
                    knownLocals.add(variable.var);
                }
            }
        }
        if (!acts) {
            return "the connect branch does nothing";
        }
        if (!usesContext) {
            // The branch has to consume the address the guard tested, otherwise it is not the connect
            // code but some other null check.
            for (AbstractInsnNode current = start; current != null && current != stop; current = current.getNext()) {
                if (current.getOpcode() == ALOAD && ((VarInsnNode) current).var != 0 && ((VarInsnNode) current).var != hostLocal) {
                    usesContext = true;
                    break;
                }
            }
        }
        if (!usesContext) {
            return "the connect branch does not use the address";
        }
        if (size > MAX_CONNECT_BRANCH_INSTRUCTIONS) {
            return "the connect branch has " + size + " instructions (limit " + MAX_CONNECT_BRANCH_INSTRUCTIONS + ")";
        }
        if (ports > 1) {
            return "the connect branch loads " + ports + " integer locals instead of at most one port";
        }
        for (AbstractInsnNode current = constructor.instructions.getFirst(); current != null; current = current.getNext()) {
            if (current instanceof JumpInsnNode && !between(current, start, stop) && between(((JumpInsnNode) current).label, start, stop)) {
                return "code outside the connect branch branches into it";
            }
        }
        for (Object block : constructor.tryCatchBlocks) {
            TryCatchBlockNode handler = (TryCatchBlockNode) block;
            if (touches(handler.start, start, stop) || touches(handler.end, start, stop) || touches(handler.handler, start, stop)) {
                return "the connect branch cuts through an exception handler";
            }
        }
        return null;
    }

    /**
     * The setters the constructor uses for the screen and the loading overlay: instance methods of the
     * game class that take a single object. Which of them is the overlay setter is decided at runtime
     * by {@link AgentBridge#onSet} - it is the one that gets cleared after the reload - so the patch
     * does not have to guess it from mapping names or from the call order (1.17/1.18 call setScreen
     * once more after setOverlay).
     */
    private static List<MethodInsnNode> findSetters(MethodNode constructor, String gameClass) {
        List<MethodInsnNode> setters = new ArrayList<MethodInsnNode>();
        for (AbstractInsnNode current = constructor.instructions.getFirst(); current != null; current = current.getNext()) {
            if (!(current instanceof MethodInsnNode)) {
                continue;
            }
            MethodInsnNode call = (MethodInsnNode) current;
            if (call.getOpcode() != INVOKEVIRTUAL || !gameClass.equals(call.owner)
                    || !call.desc.startsWith("(L") || !call.desc.endsWith(";)V")) {
                continue;
            }
            boolean seen = false;
            for (MethodInsnNode setter : setters) {
                seen |= setter.name.equals(call.name) && setter.desc.equals(call.desc);
            }
            if (!seen) {
                setters.add(call);
            }
        }
        return setters;
    }

    /** ICONST_0..ICONST_5 where possible, otherwise BIPUSH. */
    private static AbstractInsnNode intConstant(int value) {
        return value <= 5 ? new InsnNode(ICONST_0 + value) : new IntInsnNode(BIPUSH, value);
    }

    /**
     * The class an object local has to be cast back to after it travelled through the bridge as an
     * Object: the owner of the first field or method the branch uses it with.
     */
    private static String findLocalType(AbstractInsnNode start, AbstractInsnNode stop, int local) {
        for (AbstractInsnNode current = start; current != null && current != stop; current = current.getNext()) {
            if (current.getOpcode() != ALOAD || ((VarInsnNode) current).var != local) {
                continue;
            }
            for (AbstractInsnNode use = current.getNext(); use != null && use != stop; use = use.getNext()) {
                if (use.getOpcode() == ALOAD) {
                    break;
                }
                if (use instanceof FieldInsnNode) {
                    return ((FieldInsnNode) use).owner;
                }
                if (use instanceof MethodInsnNode && use.getOpcode() != INVOKESTATIC) {
                    return ((MethodInsnNode) use).owner;
                }
                if (use instanceof TypeInsnNode && use.getOpcode() == CHECKCAST) {
                    return ((TypeInsnNode) use).desc;
                }
            }
        }
        return null;
    }

    /** The frame type of a branch-local temporary: object, int, long, float, double or boolean. */
    private static Object localType(AbstractInsnNode start, AbstractInsnNode stop, int local) {
        for (AbstractInsnNode current = start; current != null && current != stop; current = current.getNext()) {
            if (current instanceof VarInsnNode && ((VarInsnNode) current).var == local) {
                switch (current.getOpcode()) {
                    case ASTORE:
                        return "java/lang/Object";
                    case ISTORE:
                        return INTEGER;
                    case LSTORE:
                        return LONG;
                    case FSTORE:
                        return FLOAT;
                    case DSTORE:
                        return DOUBLE;
                    default:
                        break;
                }
            }
        }
        return "java/lang/Object";
    }

    private static MethodNode findMethod(ClassNode classNode, String name, String desc) {
        for (MethodNode methodNode : classNode.methods) {
            if (name.equals(methodNode.name) && desc.equals(methodNode.desc)) {
                return methodNode;
            }
        }
        return null;
    }

    private static AbstractInsnNode findNext(InsnList instructions, int opcode, AbstractInsnNode from, AbstractInsnNode stop) {
        for (AbstractInsnNode current = from; current != null && current != stop; current = current.getNext()) {
            if (current.getOpcode() == opcode) {
                return current;
            }
        }
        return null;
    }

    private static boolean between(AbstractInsnNode node, AbstractInsnNode start, AbstractInsnNode stop) {
        for (AbstractInsnNode current = start; current != null && current != stop; current = current.getNext()) {
            if (current == node) {
                return true;
            }
        }
        return false;
    }

    /** True when the node is a range bound or sits between them. */
    private static boolean touches(AbstractInsnNode node, AbstractInsnNode start, AbstractInsnNode stop) {
        return between(node, start, stop) || node == stop;
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

    /**
     * The game's constructor. Forge moves the icon loading into its own method (SRG func_216529_a on
     * 1.15), so looking only for the method that loads the icon left those classes unpatched; the
     * constructor is now picked by name, preferring the one that also loads the icon and otherwise the
     * largest one (the game's own constructor).
     */
    private static MethodNode findGameConstructor(ClassNode classNode) {
        MethodNode largest = null;
        for (MethodNode methodNode : classNode.methods) {
            if (!"<init>".equals(methodNode.name)) {
                continue;
            }
            if (loadsIconResource(methodNode)) {
                return methodNode;
            }
            if (largest == null || methodNode.instructions.size() > largest.instructions.size()) {
                largest = methodNode;
            }
        }
        return largest;
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
