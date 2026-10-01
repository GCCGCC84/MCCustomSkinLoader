package customskinloader.test.agent;

import java.lang.reflect.Method;

/**
 * State for the deferJoin workaround. It lives in the agent jar, which the JVM loads with the system
 * class loader, so every Minecraft class can call it, and it only uses java.lang types: the patched
 * game class passes itself as Object and the join is invoked reflectively on the synthetic method the
 * agent added to it, so no mapping name has to be known anywhere.
 */
public final class AgentBridge {
    private static volatile Object minecraft;
    private static volatile String host;
    private static volatile int port;

    private AgentBridge() {
    }

    /** Called from Minecraft's constructor; the join itself waits for {@link #onOverlayChanged}. */
    public static void deferJoin(Object minecraftInstance, String address, int addressPort) {
        if (minecraftInstance == null || address == null) {
            return;
        }
        minecraft = minecraftInstance;
        host = address;
        port = addressPort;
        System.out.println("[agent] deferJoin: joining " + address + ":" + addressPort + " after the first resource reload");
    }

    /**
     * Called from Minecraft's overlay setter. The loading overlay is cleared exactly when the first
     * resource reload has finished, which is the point where the world may be rendered, so the join
     * runs here instead of in the constructor.
     */
    public static void onOverlayChanged(Object overlay) {
        if (overlay != null || host == null || minecraft == null) {
            return;
        }
        Object instance = minecraft;
        String address = host;
        int addressPort = port;
        minecraft = null;
        host = null;
        port = 0;
        try {
            Method join = instance.getClass().getMethod("__cslDeferredJoin", String.class, int.class);
            join.invoke(instance, address, addressPort);
            System.out.println("[agent] deferJoin: joined " + address + ":" + addressPort);
        } catch (Throwable throwable) {
            System.out.println("[agent] deferJoin: join failed: " + throwable);
        }
    }
}
