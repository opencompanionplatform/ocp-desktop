// Pixi's CSP compatibility entry replaces runtime-generated functions with
// static polyfills; despite the package path, it avoids enabling unsafe-eval.
import "pixi.js/unsafe-eval";
import { Application, Container, Graphics } from "pixi.js";
import { useEffect, useRef, useState } from "react";
import type { ReactElement } from "react";

type CharacterStageProps = Readonly<{ variant: 0 | 1 }>;

type Particle = Readonly<{
  node: Graphics;
  radius: number;
  phase: number;
  speed: number;
}>;

function createAvatar(colors: Readonly<{ suit: number; accent: number; hair: number }>): Container {
  const avatar = new Container();
  const aura = new Graphics().circle(0, -42, 92).fill({ color: colors.accent, alpha: 0.07 });
  const hairBack = new Graphics().roundRect(-44, -120, 88, 112, 38).fill(colors.hair);
  const body = new Graphics().roundRect(-35, -30, 70, 98, 24).fill(colors.suit);
  const armor = new Graphics()
    .moveTo(-34, -24)
    .lineTo(0, 12)
    .lineTo(34, -24)
    .lineTo(25, 36)
    .lineTo(-25, 36)
    .closePath()
    .fill({ color: colors.accent, alpha: 0.8 });
  const neck = new Graphics().roundRect(-12, -56, 24, 24, 8).fill(0xe7ad95);
  const face = new Graphics().ellipse(0, -78, 34, 42).fill(0xf2b9a2);
  const hairTop = new Graphics().arc(0, -86, 38, Math.PI, Math.PI * 2).stroke({ width: 24, color: colors.hair });
  const eyes = new Graphics()
    .ellipse(-13, -78, 6, 8)
    .ellipse(13, -78, 6, 8)
    .fill(0x151c35)
    .circle(-11, -80, 2)
    .circle(15, -80, 2)
    .fill(0xffffff);
  const legs = new Graphics()
    .roundRect(-28, 58, 23, 82, 10)
    .roundRect(5, 58, 23, 82, 10)
    .fill(colors.suit)
    .roundRect(-31, 124, 29, 24, 8)
    .roundRect(2, 124, 29, 24, 8)
    .fill(0x09111f);
  const arms = new Graphics()
    .roundRect(-53, -20, 18, 82, 9)
    .roundRect(35, -20, 18, 82, 9)
    .fill(colors.suit);
  const accents = new Graphics()
    .roundRect(-27, 78, 5, 34, 2)
    .roundRect(22, 78, 5, 34, 2)
    .roundRect(-49, 8, 4, 30, 2)
    .roundRect(45, 8, 4, 30, 2)
    .fill(colors.accent);
  avatar.addChild(aura, hairBack, legs, arms, body, armor, neck, face, hairTop, eyes, accents);
  return avatar;
}

export function CharacterStage({ variant }: CharacterStageProps): ReactElement {
  const hostRef = useRef<HTMLDivElement>(null);
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const targetVariantRef = useRef<0 | 1>(variant);
  const [status, setStatus] = useState<"ready" | "loading" | "context-lost">("loading");
  const [diagnostic, setDiagnostic] = useState("");

  useEffect(() => {
    targetVariantRef.current = variant;
  }, [variant]);

  useEffect(() => {
    const host = hostRef.current;
    const canvas = canvasRef.current;
    if (!host || !canvas) return;
    let disposed = false;
    let application: Application | null = null;

    const start = async (): Promise<void> => {
      const app = new Application();
      await app.init({
        canvas,
        resizeTo: host,
        preference: "webgl",
        backgroundAlpha: 0,
        antialias: true,
        autoDensity: true,
        resolution: Math.min(window.devicePixelRatio, 2),
      });
      if (disposed) {
        app.destroy();
        return;
      }
      application = app;

      const world = new Container();
      const auraLayer = new Container();
      const characterLayer = new Container();
      const particleLayer = new Container();
      const particles: Particle[] = [];
      const rings = [0, 1, 2, 3].map((index) => {
        const ring = new Graphics().ellipse(0, 0, 150 + index * 32, 34 + index * 7).stroke({
          width: index === 0 ? 2.4 : 1,
          color: index % 2 ? 0x8b5cf6 : 0x22d3ff,
          alpha: 0.42 - index * 0.06,
        });
        auraLayer.addChild(ring);
        return ring;
      });
      for (let index = 0; index < 30; index += 1) {
        const node = new Graphics().circle(0, 0, index % 5 === 0 ? 2.8 : 1.6).fill({
          color: index % 3 === 0 ? 0x9a63ff : 0x27d8ff,
          alpha: 0.75,
        });
        particleLayer.addChild(node);
        particles.push({ node, radius: 112 + (index % 7) * 23, phase: (index / 30) * Math.PI * 2, speed: 0.18 + (index % 5) * 0.035 });
      }

      const avatars = [
        createAvatar({ suit: 0x101827, accent: 0x27d8ff, hair: 0x4a241d }),
        createAvatar({ suit: 0x15142a, accent: 0xa259ff, hair: 0x15192f }),
      ];
      avatars[1].visible = false;
      characterLayer.addChild(...avatars);
      world.addChild(auraLayer, characterLayer, particleLayer);
      app.stage.addChild(world);

      let elapsed = 0;
      let displayedVariant: 0 | 1 = targetVariantRef.current;
      let switchTarget: 0 | 1 = displayedVariant;
      avatars[0].visible = displayedVariant === 0;
      avatars[1].visible = displayedVariant === 1;
      let transitionTime = 1;
      const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)");

      app.ticker.add((ticker) => {
        const seconds = ticker.deltaMS / 1000;
        elapsed += seconds;
        world.position.set(app.screen.width / 2, app.screen.height * 0.57);
        const scale = Math.max(0.72, Math.min(1.45, Math.min(app.screen.width / 620, app.screen.height / 520)));
        characterLayer.scale.set(scale);
        auraLayer.scale.set(scale);
        particleLayer.scale.set(scale);

        rings.forEach((ring, index) => {
          ring.rotation = Math.sin(elapsed * 0.25 + index) * 0.035;
          ring.alpha = 0.62 + Math.sin(elapsed * 1.4 + index) * 0.18;
        });
        particles.forEach((particle) => {
          const angle = particle.phase + elapsed * particle.speed;
          particle.node.position.set(Math.cos(angle) * particle.radius, Math.sin(angle) * particle.radius * 0.24);
          particle.node.alpha = 0.28 + (Math.sin(elapsed * 2 + particle.phase) + 1) * 0.27;
        });

        if (targetVariantRef.current !== displayedVariant && transitionTime >= 1) {
          switchTarget = targetVariantRef.current;
          transitionTime = 0;
        }
        if (transitionTime < 1) {
          transitionTime = Math.min(1, transitionTime + seconds / 0.72);
          if (reducedMotion.matches) transitionTime = 1;
          const outgoing = avatars[displayedVariant];
          if (transitionTime < 0.5) {
            outgoing.alpha = 1 - transitionTime * 2;
            outgoing.scale.set(1 - transitionTime * 0.18);
          } else {
            outgoing.visible = false;
            outgoing.alpha = 1;
            outgoing.scale.set(1);
            displayedVariant = switchTarget;
            const incoming = avatars[displayedVariant];
            incoming.visible = true;
            incoming.alpha = (transitionTime - 0.5) * 2;
            incoming.scale.set(0.91 + (transitionTime - 0.5) * 0.18);
          }
        }
        const active = avatars[displayedVariant];
        active.y = Math.sin(elapsed * 1.45) * 5 - 48;
      });
      setStatus("ready");
    };

    const onContextLost = (event: Event): void => {
      event.preventDefault();
      setDiagnostic("graphics context lost");
      setStatus("context-lost");
    };
    const onContextRestored = (): void => {
      setDiagnostic("");
      setStatus("ready");
    };
    canvas.addEventListener("webglcontextlost", onContextLost);
    canvas.addEventListener("webglcontextrestored", onContextRestored);
    void start().catch((error: unknown) => {
      const message = error instanceof Error ? error.message : "unknown initialization failure";
      console.error("[CharacterStage] WebGL initialization failed", message);
      setDiagnostic(message.slice(0, 120));
      setStatus("context-lost");
    });

    return () => {
      disposed = true;
      canvas.removeEventListener("webglcontextlost", onContextLost);
      canvas.removeEventListener("webglcontextrestored", onContextRestored);
      application?.destroy();
    };
  }, []);

  return (
    <div className="character-stage" ref={hostRef}>
      <canvas ref={canvasRef} aria-label="Animated WebGL character preview" />
      {status !== "ready" && (
        <div className="stage-fallback" role="status">
          {status === "loading" ? "Starting WebGL preview…" : `WebGL unavailable — ${diagnostic || "static preview active"}`}
        </div>
      )}
    </div>
  );
}
