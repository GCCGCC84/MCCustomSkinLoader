package net.minecraft.client;

import java.io.File;

import net.minecraft.client.multiplayer.ServerData;
import net.minecraft.client.renderer.texture.TextureManager;
import net.minecraft.server.packs.resources.ResourceManager;

public class Minecraft {
    public File gameDirectory;
    public static Minecraft getInstance() { return null; }
    public ServerData getCurrentServer() { return null; }
    public ResourceManager getResourceManager() { return null; }
    public TextureManager getTextureManager() { return null; }
}
