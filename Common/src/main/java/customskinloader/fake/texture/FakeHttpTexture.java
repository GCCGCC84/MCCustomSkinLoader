package customskinloader.fake.texture;

import java.awt.image.BufferedImage;
import java.io.File;
import java.nio.file.Path;
import java.util.AbstractMap;
import java.util.concurrent.CompletableFuture;
import java.util.function.Function;

import com.mojang.authlib.minecraft.MinecraftProfileTexture;
import com.mojang.blaze3d.platform.NativeImage;
import com.mojang.datafixers.util.Function4;
import customskinloader.fake.FakeCapeBuffer;
import customskinloader.fake.FakeMinecraftProfileTexture;
import customskinloader.fake.FakeSkinBuffer;
import customskinloader.fake.FakeSkinManager;
import customskinloader.fake.itf.FakeHttpTextureProcessor;
import customskinloader.fake.itf.FakeInterfaceManager;
import net.minecraft.client.Minecraft;
import net.minecraft.client.renderer.texture.HttpTexture;
import net.minecraft.client.renderer.texture.TextureProvider2d;
import net.minecraft.client.renderer.texture.TextureContents;
import net.minecraft.resources.Identifier;
import net.minecraft.server.packs.resources.ResourceManager;

public class FakeHttpTexture {
    public static class V1 extends HttpTexture {
        // 19w37a-
        public V1(File cacheFileIn, String imageUrlIn, Identifier textureResourceLocation, FakeHttpTextureProcessor processor, MinecraftProfileTexture texture, MinecraftProfileTexture.Type textureType) {
            super(setCacheFile(cacheFileIn, texture), imageUrlIn, textureResourceLocation, (FakeHttpTextureProcessor) setProcessor(processor, texture, textureType));
        }

        // 19w38a ~ 24w45a
        public V1(File cacheFileIn, String imageUrlIn, Identifier textureResourceLocation, boolean isSkin, Runnable processor, MinecraftProfileTexture texture, MinecraftProfileTexture.Type textureType) {
            super(setCacheFile(cacheFileIn, texture), imageUrlIn, textureResourceLocation, texture instanceof FakeMinecraftProfileTexture || isSkin, setProcessor(processor, texture, textureType));
        }

        @Override
        public void upload(BufferedImage bufferedImageIn) {
            // TextureID won't be regenerated when changing resource packs before 1.12.2
            this.uploaded = false;
            super.upload(bufferedImageIn);
        }

        private static File setCacheFile(File cacheFile, MinecraftProfileTexture texture) {
            return texture instanceof FakeMinecraftProfileTexture ? ((FakeMinecraftProfileTexture) texture).getCacheFile() : cacheFile;
        }

        private static Runnable setProcessor(Runnable processor, MinecraftProfileTexture texture, MinecraftProfileTexture.Type textureType) {
            return texture instanceof FakeMinecraftProfileTexture ? new FakeSkinManager.BaseBuffer(processor, textureType, (FakeMinecraftProfileTexture) texture) : processor;
        }
    }

    // 24w46a+ (1.21.4+)
    public static class V2 extends TextureProvider2d {
        private static final String DOMAIN = "customskinloader";

        private FakeCapeBuffer buffer;
        private FakeNativeImage image;

        public static Function<NativeImage, CompletableFuture<?>> createTexture(Function<NativeImage, CompletableFuture<?>> function, boolean isSkin, Identifier location, Function<FakeNativeImage, V2> creator) {
            return isSkin ? _image -> {
                if (location.toString().startsWith(DOMAIN + ":")) {
                    return CompletableFuture.completedFuture(new AbstractMap.SimpleEntry<>(_image, function.apply(_image)));
                }
                return function.apply(_image);
            } : _image -> {
                FakeNativeImage image = copyImage(new FakeNativeImage(_image));
                return function.apply(_image).thenApply(_location -> {
                    FakeInterfaceManager.TextureManager_registerProvider(Minecraft.getInstance().getTextureManager(), location, creator.apply(image));
                    return _location;
                });
            };
        }

        // 24w46a ~ 26.4-snapshot-2 (1.21.4 ~ 26.3)
        public static Function<FakeNativeImage, V2> createLazilyV1(Identifier location) { return image -> new V2(location, image); }
        public V2(Identifier location, FakeNativeImage image) {
            super(location);
            this.buffer = new FakeCapeBuffer();
            this.image = image;
        }

        // 26.4-snapshot-3+ (26.4+)
        public static Function<FakeNativeImage, V2> createLazilyV2(Identifier location) { return V2::new; }
        public V2(FakeNativeImage image) {
            this.buffer = new FakeCapeBuffer();
            this.image = image;
        }

        // 24w46a ~ 26.4-snapshot-2 (1.21.4 ~ 26.3)
        @Override
        public TextureContents loadContents(ResourceManager resourceManager) {
            this.image = (FakeNativeImage) this.buffer.parseUserSkin(this.image);
            return new TextureContents(copyImage(this.image).getImage(), null);
        }

        // 26.4-snapshot-3+ (26.4+)
        public TextureContents prepareState(ResourceManager resourceManager, Identifier identifier) {
            return this.loadContents(resourceManager);
        }

        /**
         * Protects cached NativeImage instances from external interference (e.g. accidental close operations). All lifecycle management is handled internally by this cache.
         */
        private static FakeNativeImage copyImage(FakeNativeImage from) {
            FakeNativeImage local = (FakeNativeImage) from.createImage(from.getWidth(), from.getHeight());
            local.copyImageData(from);
            return local;
        }

        // 24w46a+
        public static CompletableFuture<?> downloadAndRegisterSkin(
            Function4<Identifier, Path, String, Boolean, CompletableFuture<AbstractMap.SimpleEntry<NativeImage, CompletableFuture<?>>>> downloadAndRegisterSkin, Identifier location, Path cacheFile, String imageUrl, boolean isSkin, MinecraftProfileTexture texture) {
            if (isSkin && texture instanceof FakeMinecraftProfileTexture) {
                location = new Identifier(DOMAIN, location.toString().split(":")[1]);
                return downloadAndRegisterSkin.apply(location, setCacheFile(cacheFile, texture), imageUrl, isSkin).thenApply(entry -> {
                    FakeSkinManager.BaseBuffer.judgeType((FakeMinecraftProfileTexture) texture, () -> FakeSkinBuffer.judgeType0(new FakeNativeImage(entry.getKey())));
                    return entry.getValue();
                }).thenCompose(f -> f);
            }
            return downloadAndRegisterSkin.apply(location, setCacheFile(cacheFile, texture), imageUrl, isSkin);
        }

        private static Path setCacheFile(Path cacheFile, MinecraftProfileTexture texture) {
            return texture instanceof FakeMinecraftProfileTexture ? ((FakeMinecraftProfileTexture) texture).getCacheFile().toPath() : cacheFile;
        }
    }
}
