# Controlled tessellation experiments

Baseline source and mod: `198a7c30c63c2059df0370ffcb327a024fc6088c`, original `CustomSkinLoader-GameTest-7` artifact from run 35731352175.

Initial matrix: Minecraft 1.14.4 / Fabric 0.19.5 and Minecraft 1.16 / Quilt 0.30.1. Each combination runs all four cells of with/without CSL × immediate/deferred server connection. Runtime is Temurin 8u504 and Mesa 26.2.0, matching the original run. All cells use the same fixed GUI scale/language and dismiss the multiplayer warning through options.txt.

The deferred condition removes startup server arguments, waits for the late resource-atlas marker plus 10 seconds, and enters the local server through the normal multiplayer GUI. The observation period is 90 seconds after the server records a join. The probe records whether the client actually receives advancements, whether the CSL profile loads, process exit, crash text, and screenshots. Exit status of the workflow means collection completed, not that the game passed: inspect each `result.json`.

Only the diagnostic workflow runs on this branch. No build or publish jobs are triggered; the original tested mod is reused to avoid changing the implementation under investigation.
