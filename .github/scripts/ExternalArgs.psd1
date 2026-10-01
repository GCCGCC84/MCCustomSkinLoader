# Workarounds for game-test failures that are caused by the environment (game version, mod loader,
# headless GL) rather than by CustomSkinLoader itself.
#
# Every entry is one named workaround plus the combos it applies to:
#
#   Name    Workaround id, logged by Prepare-TestVersion.ps1 for every client it is applied to. For
#           agent workarounds the Agent.java branch of the same name is selected through JvmArgs and
#           a -javaagent argument must carry it as the agent argument list.
#   Matrix  Mod loaders and Minecraft version range the workaround is applied to.
#   JvmArgs Extra JVM arguments. JPLIS splits -javaagent at the first '=', so write
#           '-javaagent:CustomSkinLoader-Test-1.0.0.jar=<id>[,<id>...]'. With ':' instead of '=' the
#           JVM looks for a file named "<jar>:<id>" and the client dies before main().
#   AppArgs Extra game arguments.
#
# The purpose is the comment above each entry, and an entry is only considered alive while the CI
# game-test jobs of its combos pass in a normal run (no skipped loader, no retry, no disabled combo):
# that is the verification. Entries that are known to be insufficient carry a "NOT verified yet" note
# with the failure that is still observed.
@{
    Args = @(
        @{
            # The client connects to the server address (--server) while the first resource reload is
            # still running, so it renders the world before the block atlas and the shaders exist.
            # Observed on 1.15.1 as ReportedException "Rendering overlay" raised from
            # ConnectingScreen.<init>, on 1.18 as NPE in ShaderInstance.getUniform() plus
            # FileNotFoundException textures/atlas/blocks.png. deferJoin moves the auto-connect part of
            # Minecraft's constructor behind the rest of the constructor so the join happens once the
            # loading overlay is installed.
            Name    = 'deferJoin'
            Matrix  = @(
                @{
                    Loaders = @('fabric', 'quilt')
                    VersionRange = @('1.14', '1.17')
                }
            )
            JvmArgs = '-javaagent:CustomSkinLoader-Test-1.0.0.jar=deferJoin'
        },
        @{
            # deferJoin from above plus the Forge ModLauncher network classes: on 1.13.2-1.14.3 the
            # login handshake resolves them lazily while the client is already ticking, which races
            # the class loader. preloadForgeNetwork defines them on the game class loader as soon as
            # that loader is known instead.
            Name    = 'deferJoin,preloadForgeNetwork'
            Matrix  = @(
                @{
                    Loaders = @('forge')
                    VersionRange = @('1.13.2', '1.14.3')
                }
            )
            JvmArgs = '-javaagent:CustomSkinLoader-Test-1.0.0.jar=deferJoin,preloadForgeNetwork'
        },
        @{
            # Quilt 0.30.1 loads com.mojang:blocklist and com.mojang:patchy in two different class
            # loaders, so ServiceLoader rejects MojangBlockListSupplier and the connection thread
            # dies. Declaring both jars as loader.systemLibraries keeps them in one loader.
            Name    = 'quiltSystemLibraries'
            Matrix  = @(
                @{
                    Loaders = @('quilt')
                    VersionRange = @('1.17.1', '1.17.1')
                }
            )
            JvmArgs = '-Dloader.systemLibraries=${library_directory}/com/mojang/blocklist/1.0.5/blocklist-1.0.5.jar${classpath_separator}${library_directory}/com/mojang/patchy/2.1.6/patchy-2.1.6.jar'
        },
        @{
            # Same as above with the 1.18 jars.
            # NOT verified yet: 1.18:quilt still fails on the early connect, see deferJoin.
            Name    = 'quiltSystemLibraries'
            Matrix  = @(
                @{
                    Loaders = @('quilt')
                    VersionRange = @('1.18', '1.18.1')
                }
            )
            JvmArgs = '-Dloader.systemLibraries=${library_directory}/com/mojang/blocklist/1.0.6/blocklist-1.0.6.jar${classpath_separator}${library_directory}/com/mojang/patchy/2.1.6/patchy-2.1.6.jar'
        }
        # 1.16.4/1.16.5 deliberately have no entry: the client drops the server address because
        # Minecraft.allowsMultiplayer() asks authlib's SocialInteractionsService.serversAllowed(),
        # which is false for the throw-away session the tests use, so the client silently stays on the
        # title screen (no log line, no screenshot, harness timeout). Sending the authlib calls into a
        # dead proxy (the previous workaround) does not change that. The agent has to make the
        # deferred join independent of the multiplayer permission instead of faking the network.
    )
}
