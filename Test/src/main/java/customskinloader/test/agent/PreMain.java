package customskinloader.test.agent;

import java.lang.instrument.Instrumentation;

import customskinloader.test.agent.impl.ForgeNetworkFixTransformer;
import customskinloader.test.agent.impl.MC145102FixTransformer;

public final class PreMain {
    public static void premain(String agentArgs, Instrumentation instrumentation) {
        switch(agentArgs) {
            case "ForgeNetworkFix":
                instrumentation.addTransformer(new ForgeNetworkFixTransformer());
                break;
            case "MC145102Fix":
                instrumentation.addTransformer(new MC145102FixTransformer());
                break;
        }
    }
}
