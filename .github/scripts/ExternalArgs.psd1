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
            # FileNotFoundException textures/atlas/blocks.png, on 1.14.1 as NPE "Tesselating block in
            # world". deferJoin makes the client start on the title screen, keeps the address and joins
            # when the loading overlay is cleared, i.e. after the first resource reload.
            # It applies to the vanilla constructor shapes of 1.15-1.18 and steps aside (logging why) on
            # 1.14.x, whose connect branch sits inside exception handlers, and on 1.19.1, whose branch
            # reads extra locals; both need their own anchoring.
            Name    = 'deferJoin'
            Matrix  = @(
                @{
                    Loaders = @('fabric', 'quilt')
                    VersionRange = @('1.14', '1.17')
                },
                @{
                    # The old game-test harness covered these with its own deferred join; the current
                    # harness only passes the server address. Forge 1.15/1.15.1 raise
                    # ReportedException "Rendering overlay" while ConnectingScreen is created, Quilt
                    # 1.18/1.18.2 crash with an NPE in ShaderInstance.getUniform() and Quilt 1.19.1
                    # connects but never finishes the first resource reload.
                    # Forge 1.16.4/1.16.5 are flaky without it (run 7 passed, run 8 failed) and get
                    # allowMultiplayer from the entry below at the same time.
                    Loaders = @('forge')
                    VersionRange = @('1.15', '1.15.1', '1.16.4', '1.16.5')
                },
                @{
                    # 1.17.1 and 1.18.1 hit the same race but only intermittently (they passed in run 3
                    # and failed in run 7 without a workaround), so they are covered here as well.
                    Loaders = @('quilt')
                    VersionRange = @('1.17.1', '1.17.1', '1.18.1', '1.18.1')
                },
                @{
                    Loaders = @('quilt')
                    VersionRange = @('1.18', '1.18', '1.18.2', '1.18.2', '1.19.1', '1.19.1')
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
            # 1.16.4 added "if (allowsMultiplayer() && serverAddress != null)" to Minecraft's
            # constructor, and allowsMultiplayer() asks authlib's SocialInteractionsService, which is
            # false for the throw-away session the game tests use. The client then drops the server
            # address and stays on the title screen: no connect attempt, no log line, no crash, no
            # screenshot, only the harness timeout. Routing the authlib calls into a dead proxy (the
            # earlier --proxyHost workaround) does not change that; allowMultiplayer removes exactly
            # that branch. 1.16.1-1.16.3 pass without it, 1.16.4 is where the branch was introduced.
            Name    = 'allowMultiplayer'
            Matrix  = @(
                @{
                    Loaders = @('fabric', 'forge', 'quilt')
                    VersionRange = @('1.16.4', '1.16.5')
                }
            )
            JvmArgs = '-javaagent:CustomSkinLoader-Test-1.0.0.jar=allowMultiplayer'
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
        # Note: the fabric/quilt combos of 1.16.4/1.16.5 receive deferJoin from the first entry and
        # allowMultiplayer from the entry above; Prepare-TestVersion.ps1 merges both ids into one
        # -javaagent argument so the agent jar is loaded exactly once.
    )
}
