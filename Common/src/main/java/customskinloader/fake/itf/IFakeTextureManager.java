package customskinloader.fake.itf;

import net.minecraft.client.renderer.texture.TextureManager;
import net.minecraft.client.renderer.texture.TextureProvider;
import net.minecraft.resources.Identifier;

public interface IFakeTextureManager {
    // 24w46a ~ 26.4-snapshot-2 + 26.4-snapshot-8+ (1.21.4+)
    default void registerProvider(Identifier textureId, TextureProvider texture) {
        ((TextureManager) this).registerAndLoad(textureId, texture);
    }
}
