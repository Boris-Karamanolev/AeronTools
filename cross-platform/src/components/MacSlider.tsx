import { useEffect, useRef, useState } from "react";

interface MacSliderProps {
  value: number;
  min?: number;
  max?: number;
  step?: number;
  disabled?: boolean;
  throttleMs?: number;
  accentColor?: string;
  onChange: (value: number) => void;
  onDisplayValueChange?: (value: number) => void;
  ariaLabel?: string;
}

/**
 * Native macOS-style thin capsule slider (4px track, accent fill, crisp 14px white knob).
 *
 * Uses cached track geometry + direct DOM/GPU updates on pointer move so dragging glides
 * pixel-smoothly at 60–120Hz with zero layout reflow, while coalescing hardware writes and
 * ignoring stale prop echoes right after release.
 */
export function MacSlider({
  value,
  min = 0,
  max = 1,
  step = 0.01,
  disabled = false,
  throttleMs = 25,
  accentColor = "#0a84ff",
  onChange,
  onDisplayValueChange,
  ariaLabel,
}: MacSliderProps) {
  const clamp = (raw: number) => Math.min(max, Math.max(min, raw));
  const quantize = (raw: number) => {
    const clamped = clamp(raw);
    if (step <= 0) return clamped;
    const steps = Math.round((clamped - min) / step);
    return Number((min + steps * step).toFixed(4));
  };
  const toRatio = (v: number) =>
    max > min ? Math.min(1, Math.max(0, (v - min) / (max - min))) : 0;

  const [visualRatio, setVisualRatio] = useState(() => toRatio(value));
  const draggingRef = useRef(false);
  const lastReleaseRef = useRef(0);
  const trackRef = useRef<HTMLDivElement | null>(null);
  const fillRef = useRef<HTMLDivElement | null>(null);
  const thumbRef = useRef<HTMLDivElement | null>(null);
  const trackRectRef = useRef<{ left: number; width: number } | null>(null);

  const lastEmitTimeRef = useRef(0);
  const lastEmittedValRef = useRef<number>(quantize(value));
  const pendingTimerRef = useRef<number | null>(null);
  const latestValRef = useRef<number>(quantize(value));
  const displayCallbackRef = useRef(onDisplayValueChange);
  displayCallbackRef.current = onDisplayValueChange;

  const applyVisualRatio = (ratio: number) => {
    const clampedRatio = Math.min(1, Math.max(0, ratio));
    if (fillRef.current) {
      fillRef.current.style.transform = `scaleX(${clampedRatio})`;
    }
    if (thumbRef.current) {
      thumbRef.current.style.left = `${clampedRatio * 100}%`;
    }
  };

  // Sync external `value` prop only when not dragging and outside the post-release settle window
  useEffect(() => {
    if (draggingRef.current) return;
    if (performance.now() - lastReleaseRef.current < 450) return;
    const q = quantize(value);
    const ratio = toRatio(value);
    latestValRef.current = q;
    lastEmittedValRef.current = q;
    setVisualRatio(ratio);
    applyVisualRatio(ratio);
    displayCallbackRef.current?.(q);
  }, [value, min, max, step]);

  useEffect(() => {
    return () => {
      if (pendingTimerRef.current !== null) {
        window.clearTimeout(pendingTimerRef.current);
      }
    };
  }, []);

  const emitThrottled = (next: number, flush = false) => {
    latestValRef.current = next;
    const now = performance.now();
    if (flush) {
      if (pendingTimerRef.current !== null) {
        window.clearTimeout(pendingTimerRef.current);
        pendingTimerRef.current = null;
      }
      lastEmitTimeRef.current = now;
      lastEmittedValRef.current = next;
      onChange(next);
      return;
    }
    if (next === lastEmittedValRef.current) return;
    const elapsed = now - lastEmitTimeRef.current;
    if (elapsed >= throttleMs) {
      lastEmitTimeRef.current = now;
      lastEmittedValRef.current = next;
      onChange(next);
    } else if (pendingTimerRef.current === null) {
      pendingTimerRef.current = window.setTimeout(() => {
        pendingTimerRef.current = null;
        if (latestValRef.current !== lastEmittedValRef.current) {
          lastEmitTimeRef.current = performance.now();
          lastEmittedValRef.current = latestValRef.current;
          onChange(latestValRef.current);
        }
      }, throttleMs - elapsed);
    }
  };

  const ratioFromClientX = (clientX: number) => {
    const rect =
      trackRectRef.current ??
      (() => {
        const el = trackRef.current;
        if (!el) return null;
        const r = el.getBoundingClientRect();
        return { left: r.left, width: Math.max(1, r.width) };
      })();
    if (!rect) return visualRatio;
    return Math.min(1, Math.max(0, (clientX - rect.left) / rect.width));
  };

  const handlePointerPosition = (clientX: number, flush: boolean) => {
    const ratio = ratioFromClientX(clientX);
    const quantized = quantize(min + ratio * (max - min));
    // Smooth continuous thumb motion during drag; snap cleanly to quantized step on release
    const renderRatio = flush ? toRatio(quantized) : ratio;
    applyVisualRatio(renderRatio);
    if (flush) {
      setVisualRatio(renderRatio);
    }
    if (quantized !== latestValRef.current || flush) {
      displayCallbackRef.current?.(quantized);
    }
    emitThrottled(quantized, flush);
  };

  return (
    <div
      ref={trackRef}
      role="slider"
      tabIndex={disabled ? -1 : 0}
      aria-label={ariaLabel}
      aria-valuemin={min}
      aria-valuemax={max}
      aria-valuenow={latestValRef.current}
      aria-disabled={disabled}
      onPointerDown={(e) => {
        if (disabled) return;
        e.currentTarget.setPointerCapture(e.pointerId);
        const r = e.currentTarget.getBoundingClientRect();
        trackRectRef.current = { left: r.left, width: Math.max(1, r.width) };
        draggingRef.current = true;
        handlePointerPosition(e.clientX, false);
      }}
      onPointerMove={(e) => {
        if (!draggingRef.current || disabled) return;
        handlePointerPosition(e.clientX, false);
      }}
      onPointerUp={(e) => {
        if (!draggingRef.current) return;
        draggingRef.current = false;
        lastReleaseRef.current = performance.now();
        handlePointerPosition(e.clientX, true);
        trackRectRef.current = null;
      }}
      onPointerCancel={() => {
        if (!draggingRef.current) return;
        draggingRef.current = false;
        lastReleaseRef.current = performance.now();
        trackRectRef.current = null;
        const ratio = toRatio(latestValRef.current);
        setVisualRatio(ratio);
        applyVisualRatio(ratio);
        emitThrottled(latestValRef.current, true);
      }}
      onKeyDown={(e) => {
        if (disabled) return;
        const delta = (max - min) * 0.05;
        if (e.key === "ArrowRight" || e.key === "ArrowUp") {
          e.preventDefault();
          const next = quantize(latestValRef.current + Math.max(step, delta));
          const ratio = toRatio(next);
          lastReleaseRef.current = performance.now();
          setVisualRatio(ratio);
          applyVisualRatio(ratio);
          displayCallbackRef.current?.(next);
          emitThrottled(next, true);
        } else if (e.key === "ArrowLeft" || e.key === "ArrowDown") {
          e.preventDefault();
          const next = quantize(latestValRef.current - Math.max(step, delta));
          const ratio = toRatio(next);
          lastReleaseRef.current = performance.now();
          setVisualRatio(ratio);
          applyVisualRatio(ratio);
          displayCallbackRef.current?.(next);
          emitThrottled(next, true);
        }
      }}
      className={`relative flex h-5 flex-1 touch-none select-none items-center ${
        disabled ? "cursor-default opacity-40" : "cursor-pointer"
      }`}
    >
      {/* Background track */}
      <div className="relative h-[4px] w-full overflow-hidden rounded-full bg-white/[0.14]">
        <div
          ref={fillRef}
          className="h-full w-full origin-left rounded-full will-change-transform"
          style={{
            transform: `scaleX(${visualRatio})`,
            backgroundColor: disabled ? "rgba(255,255,255,0.28)" : accentColor,
          }}
        />
      </div>

      {/* macOS circular white thumb */}
      <div
        ref={thumbRef}
        className="pointer-events-none absolute top-1/2 h-[14px] w-[14px] -translate-x-1/2 -translate-y-1/2 rounded-full bg-[#f5f5f7] will-change-[left]"
        style={{
          left: `${visualRatio * 100}%`,
          boxShadow: "0 1px 3px rgba(0,0,0,0.5), 0 0 0 0.5px rgba(0,0,0,0.28)",
        }}
      />
    </div>
  );
}
