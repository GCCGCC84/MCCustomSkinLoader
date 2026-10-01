package customskinloader.test.agent;

import java.lang.reflect.Method;

/**
 * State for the deferJoin workaround. It lives in the agent jar, which the JVM loads with the system
 * class loader, so every Minecraft class can call it, and it only uses java.lang types: the patched
 * game class passes itself as Object, and the join is invoked reflectively on the synthetic method the
 * agent added to it, so no mapping name has to be known anywhere.
 */
public final class AgentBridge {
    private static volatile boolean screenSeen;
    private static volatile Object minecraft;
    private static volatile String host;
    private static volatile int port;
    private static volatile Object[] extras;

    private AgentBridge() {
    }

    /**
     * Called from Minecraft's constructor; the join itself waits for {@link #onSet}. The address may be
     * null: 1.14 keeps host and port inside an object that arrives through {@code extraLocals}, and the
     * generated method then ignores its own String and int parameters.
     */
    public static void deferJoin(Object minecraftInstance, String address, int addressPort, Object[] extraLocals) {
        if (minecraftInstance == null) {
            return;
        }
        minecraft = minecraftInstance;
        host = address;
        port = addressPort;
        extras = extraLocals == null ? new Object[0] : extraLocals;
        System.out.println("[agent] deferJoin: joining " + (address == null ? "the address in the extras" : address + ":" + addressPort)
                + " after the first resource reload");
    }

    /**
     * Called from the screen and overlay setters of the game class. A screen shows up first (the title
     * screen the constructor sets) and the loading overlay is cleared exactly when the first resource
     * reload has finished, which is the point where the world may be rendered: that clear is what the
     * pending join waits for, no matter which of the setters it is.
     */
    public static void onSet(Object value, String setter) {
        if (value != null) {
            screenSeen = true;
            return;
        }
        if (!screenSeen || minecraft == null) {
            return;
        }
        final Object instance = minecraft;
        final String address = host;
        final int addressPort = port;
        final Object[] extraLocals = extras;
        minecraft = null;
        host = null;
        port = 0;
        extras = null;
        screenSeen = false;
        System.out.println("[agent] deferJoin: overlay cleared by " + setter + ", joining now");
        joinNow(instance, address, addressPort, extraLocals);
    }

    private static void joinNow(Object instance, String address, int addressPort, Object[] extraLocals) {
        try {
            Method join = instance.getClass().getMethod("__cslDeferredJoin", String.class, int.class, Object[].class);
            join.invoke(instance, address, addressPort, extraLocals);
            System.out.println("[agent] deferJoin: joined " + address + ":" + addressPort);
        } catch (Throwable throwable) {
            System.out.println("[agent] deferJoin: join failed: " + throwable);
        }
    }
}
