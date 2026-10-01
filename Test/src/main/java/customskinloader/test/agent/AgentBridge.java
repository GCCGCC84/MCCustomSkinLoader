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

    /** Called from Minecraft's constructor; the join itself waits for {@link #onSet}. */
    public static void deferJoin(Object minecraftInstance, String address, int addressPort, Object[] extraLocals) {
        if (minecraftInstance == null || address == null) {
            return;
        }
        minecraft = minecraftInstance;
        host = address;
        port = addressPort;
        extras = extraLocals == null ? new Object[0] : extraLocals;
        System.out.println("[agent] deferJoin: joining " + address + ":" + addressPort
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
        if (!screenSeen || host == null || minecraft == null) {
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
        final Runnable join = new Runnable() {
            @Override
            public void run() {
                joinNow(instance, address, addressPort, extraLocals);
            }
        };
        // Joining right here runs inside the render thread's resource reload path; 1.15/1.15.1/1.17
        // joined and then went silent for the rest of the test window that way. Hand the work to the
        // game's own task queue instead - a void method taking a single Runnable, found by shape, so no
        // mapping name is involved - which runs it at the next safe point of the main loop.
        Method executor = findExecutor(instance);
        if (executor == null) {
            System.out.println("[agent] deferJoin: overlay cleared by " + setter + ", no task queue, joining inline");
            join.run();
            return;
        }
        try {
            System.out.println("[agent] deferJoin: overlay cleared by " + setter + ", joining on the game thread");
            executor.invoke(instance, join);
        } catch (Throwable throwable) {
            System.out.println("[agent] deferJoin: scheduling failed (" + throwable + "), joining inline");
            join.run();
        }
    }

    /** A void method of the game class taking a single Runnable, i.e. its task queue. */
    private static Method findExecutor(Object instance) {
        for (Method method : instance.getClass().getMethods()) {
            Class<?>[] parameters = method.getParameterTypes();
            if (parameters.length == 1 && parameters[0] == Runnable.class && method.getReturnType() == void.class) {
                return method;
            }
        }
        return null;
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
