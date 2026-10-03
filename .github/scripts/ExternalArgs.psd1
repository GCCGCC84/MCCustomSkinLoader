# This configuration file contains workarounds for various issues unrelated to this mod
# that may occur when running CI tests on certain Minecraft versions.
@{
    Args = @(
        @{ #
            Matrix = @(
                @{
                    Loaders = @('fabric', 'quilt')
                    VersionRange = @('1.14', '1.17')
                }
            )
            JvmArgs = '-javaagent:CustomSkinLoader-Test-1.0.0.jar=MC145102Fix'
        },
        @{ #
            Matrix = @(
                @{
                    Loaders = @('forge')
                    VersionRange = @('1.13.2', '1.13.2')
                }
            )
            JvmArgs = '-javaagent:CustomSkinLoader-Test-1.0.0.jar=ForgeNetworkFix'
        },
        @{ # Work around the 1.16.4/1.16.5 authlib returning invalid data and disabling multiplayer by setting an invalid proxy address.
            Matrix = @(
                @{
                    Loaders = @('fabric', 'forge', 'quilt')
                    VersionRange = @('1.16.4', '1.16.5')
                }
            )
            AppArgs = '--proxyHost 127.0.0.1'
        },
        @{ #
            Matrix = @(
                @{
                    Loaders = @('quilt')
                    VersionRange = @('1.17.1', '1.17.1')
                }
            )
            JvmArgs = '-Dloader.systemLibraries=${library_directory}/com/mojang/blocklist/1.0.5/blocklist-1.0.5.jar${classpath_separator}${library_directory}/com/mojang/patchy/2.1.6/patchy-2.1.6.jar'
        },
        @{ #
            Matrix = @(
                @{
                    Loaders = @('quilt')
                    VersionRange = @('1.18', '1.18.1')
                }
            )
            JvmArgs = '-Dloader.systemLibraries=${library_directory}/com/mojang/blocklist/1.0.6/blocklist-1.0.6.jar${classpath_separator}${library_directory}/com/mojang/patchy/2.1.6/patchy-2.1.6.jar'
        }
    )
}
