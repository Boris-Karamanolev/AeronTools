import Foundation

// MARK: - Embedded Zero-Dependency Web Client for Tesla / iPad / Browser

nonisolated enum WebClientHTML {
    static func render(
        config: WirelessDisplayConfig,
        touchEnabled: Bool
    ) -> String {
        let targetFPS = config.fps
        let resolutionLabel = "\(config.preset.width)×\(config.preset.height)"

        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
            <meta charset="utf-8" />
            <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no, viewport-fit=cover" />
            <meta name="apple-mobile-web-app-capable" content="yes" />
            <meta name="apple-mobile-web-app-status-bar-style" content="black-translucent" />
            <title>Aeron Tools · Wireless Display</title>
            <style>
                * { box-sizing: border-box; margin: 0; padding: 0; -webkit-user-select: none; user-select: none; -webkit-touch-callout: none; }
                html, body {
                    width: 100vw;
                    height: 100vh;
                    overflow: hidden;
                    background: #05070a;
                    color: #f4f7fb;
                    font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Segoe UI", sans-serif;
                    touch-action: none;
                }
                #stage {
                    position: fixed;
                    inset: 0;
                    display: flex;
                    align-items: center;
                    justify-content: center;
                    background: #05070a;
                }
                #screenCanvas {
                    max-width: 100vw;
                    max-height: 100vh;
                    width: 100vw;
                    height: 100vh;
                    object-fit: contain;
                    cursor: crosshair;
                    display: block;
                }
                body.fill-mode #screenCanvas {
                    object-fit: fill;
                }
                #hud {
                    position: fixed;
                    top: 14px;
                    left: 50%;
                    transform: translateX(-50%);
                    display: flex;
                    align-items: center;
                    gap: 8px;
                    padding: 8px 14px;
                    background: rgba(14, 18, 26, 0.84);
                    backdrop-filter: blur(16px);
                    -webkit-backdrop-filter: blur(16px);
                    border: 1px solid rgba(255, 255, 255, 0.14);
                    border-radius: 999px;
                    z-index: 100;
                    transition: opacity 0.28s ease, transform 0.28s ease;
                    box-shadow: 0 12px 32px rgba(0, 0, 0, 0.45);
                }
                #hud.hidden {
                    opacity: 0;
                    pointer-events: none;
                    transform: translateX(-50%) translateY(-16px);
                }
                .badge {
                    display: inline-flex;
                    align-items: center;
                    gap: 6px;
                    font-size: 12px;
                    font-weight: 600;
                    color: #8ce99a;
                    padding: 4px 10px;
                    border-radius: 999px;
                    background: rgba(46, 204, 113, 0.14);
                }
                .res-label {
                    font-size: 12px;
                    font-weight: 500;
                    color: #a5b4cb;
                    padding: 0 4px;
                }
                .dot {
                    width: 7px;
                    height: 7px;
                    border-radius: 50%;
                    background: #2ecc71;
                    box-shadow: 0 0 8px #2ecc71;
                }
                .hud-btn {
                    appearance: none;
                    border: 1px solid rgba(255, 255, 255, 0.16);
                    background: rgba(255, 255, 255, 0.07);
                    color: #e9eef7;
                    font-size: 12px;
                    font-weight: 600;
                    padding: 6px 12px;
                    border-radius: 999px;
                    cursor: pointer;
                    transition: background 0.15s ease, border-color 0.15s ease;
                }
                .hud-btn:hover, .hud-btn.active {
                    background: rgba(56, 139, 253, 0.32);
                    border-color: rgba(88, 166, 255, 0.75);
                    color: #ffffff;
                }
                #hudTogglePill {
                    position: fixed;
                    top: 8px;
                    right: 12px;
                    z-index: 101;
                    width: 34px;
                    height: 34px;
                    border-radius: 50%;
                    border: 1px solid rgba(255,255,255,0.18);
                    background: rgba(15, 20, 28, 0.65);
                    color: #d0d8e8;
                    font-size: 14px;
                    display: flex;
                    align-items: center;
                    justify-content: center;
                    cursor: pointer;
                }
                #touchRipple {
                    position: fixed;
                    width: 28px;
                    height: 28px;
                    border-radius: 50%;
                    border: 2px solid rgba(88, 166, 255, 0.85);
                    background: rgba(88, 166, 255, 0.22);
                    pointer-events: none;
                    transform: translate(-50%, -50%) scale(0.4);
                    opacity: 0;
                    z-index: 90;
                    transition: transform 0.22s ease-out, opacity 0.22s ease-out;
                }
                #touchRipple.active {
                    transform: translate(-50%, -50%) scale(1.1);
                    opacity: 1;
                }
            </style>
        </head>
        <body>
            <div id="stage">
                <canvas id="screenCanvas" width="\(config.preset.width)" height="\(config.preset.height)"></canvas>
            </div>

            <div id="touchRipple"></div>

            <button id="hudTogglePill" title="Toggle HUD" onclick="toggleHUD()">⚙</button>

            <div id="hud">
                <span class="badge"><span class="dot" id="statusDot"></span><span id="fpsLabel">LIVE</span></span>
                <span class="res-label">\(resolutionLabel)</span>
                <button class="hud-btn" id="touchBtn" onclick="toggleTouch()">Touch: \(touchEnabled ? "ON" : "OFF")</button>
                <button class="hud-btn" id="fitBtn" onclick="toggleScaleMode()">Aspect: Fit</button>
                <button class="hud-btn" onclick="enterFullScreen()">Fullscreen</button>
            </div>

            <script>
                let touchEnabled = \(touchEnabled ? "true" : "false");
                let targetFPS = \(targetFPS);
                let fillMode = false;
                let hudVisible = true;
                let hudHideTimer = null;

                const canvas = document.getElementById('screenCanvas');
                const ctx = canvas.getContext('2d', { alpha: false, desynchronized: true });
                const fpsLabel = document.getElementById('fpsLabel');
                const statusDot = document.getElementById('statusDot');
                const hud = document.getElementById('hud');
                const ripple = document.getElementById('touchRipple');

                let frameCount = 0;
                let lastStatTime = performance.now();
                let lastFrameIndex = 0;
                let cachedRect = canvas.getBoundingClientRect();

                function updateCachedRect() {
                    cachedRect = canvas.getBoundingClientRect();
                }
                window.addEventListener('resize', updateCachedRect, { passive: true });
                document.addEventListener('fullscreenchange', updateCachedRect, { passive: true });

                function scheduleHUDAutoHide() {
                    if (hudHideTimer) clearTimeout(hudHideTimer);
                    hudHideTimer = setTimeout(() => {
                        hud.classList.add('hidden');
                        hudVisible = false;
                    }, 4500);
                }

                function toggleHUD() {
                    hudVisible = !hudVisible;
                    hud.classList.toggle('hidden', !hudVisible);
                    if (hudVisible) scheduleHUDAutoHide();
                }

                function toggleTouch() {
                    touchEnabled = !touchEnabled;
                    document.getElementById('touchBtn').textContent = 'Touch: ' + (touchEnabled ? 'ON' : 'OFF');
                    scheduleHUDAutoHide();
                }

                function toggleScaleMode() {
                    fillMode = !fillMode;
                    document.body.classList.toggle('fill-mode', fillMode);
                    document.getElementById('fitBtn').textContent = fillMode ? 'Aspect: Fill' : 'Aspect: Fit';
                    updateCachedRect();
                    scheduleHUDAutoHide();
                }

                function enterFullScreen() {
                    const el = document.documentElement;
                    if (el.requestFullscreen) el.requestFullscreen();
                    else if (el.webkitRequestFullscreen) el.webkitRequestFullscreen();
                    scheduleHUDAutoHide();
                }

                async function decodeAndDraw(blob) {
                    if (window.createImageBitmap) {
                        const bmp = await createImageBitmap(blob);
                        if (canvas.width !== bmp.width || canvas.height !== bmp.height) {
                            canvas.width = bmp.width;
                            canvas.height = bmp.height;
                            updateCachedRect();
                        }
                        ctx.drawImage(bmp, 0, 0);
                        bmp.close();
                    } else {
                        await drawFallbackBlob(blob);
                    }
                    frameCount++;
                }

                // Event-driven long-poll + pipelined GPU decode loop.
                // Overlaps network transfer of frame N+1 with bitmap decode of frame N.
                async function pumpFrames() {
                    let pendingDecode = null;
                    while (true) {
                        try {
                            const res = await fetch(`/frame.jpg?last=${lastFrameIndex}&wait=1`, {
                                cache: 'no-store'
                            });
                            if (res.status === 204) {
                                statusDot.style.background = '#2ecc71';
                            } else if (res.ok) {
                                const frameHeader = res.headers.get('X-Frame-Index');
                                if (frameHeader) {
                                    lastFrameIndex = parseInt(frameHeader, 10) || lastFrameIndex;
                                }
                                const blob = await res.blob();
                                if (blob.size > 0) {
                                    if (pendingDecode) await pendingDecode;
                                    pendingDecode = decodeAndDraw(blob);
                                    statusDot.style.background = '#2ecc71';
                                }
                            } else {
                                statusDot.style.background = '#f39c12';
                                await new Promise(r => setTimeout(r, 120));
                            }
                        } catch (err) {
                            statusDot.style.background = '#e74c3c';
                            await new Promise(r => setTimeout(r, 250));
                        }

                        const now = performance.now();
                        if (now - lastStatTime >= 1000) {
                            const fps = Math.round((frameCount * 1000) / (now - lastStatTime));
                            fpsLabel.textContent = fps > 0 ? `${fps} FPS` : 'IDLE';
                            frameCount = 0;
                            lastStatTime = now;
                        }
                    }
                }

                function drawFallbackBlob(blob) {
                    return new Promise((resolve) => {
                        const url = URL.createObjectURL(blob);
                        const img = new Image();
                        img.onload = () => {
                            if (canvas.width !== img.naturalWidth || canvas.height !== img.naturalHeight) {
                                canvas.width = img.naturalWidth;
                                canvas.height = img.naturalHeight;
                                updateCachedRect();
                            }
                            ctx.drawImage(img, 0, 0);
                            URL.revokeObjectURL(url);
                            resolve();
                        };
                        img.onerror = () => {
                            URL.revokeObjectURL(url);
                            resolve();
                        };
                        img.src = url;
                    });
                }

                // Compute normalized (0..1) coordinates inside the rendered video area (accounting for object-fit: contain)
                function normalizedCanvasCoords(clientX, clientY) {
                    const rect = cachedRect.width > 0 ? cachedRect : canvas.getBoundingClientRect();
                    if (fillMode || !canvas.width || !canvas.height) {
                        return {
                            x: Math.min(1, Math.max(0, (clientX - rect.left) / rect.width)),
                            y: Math.min(1, Math.max(0, (clientY - rect.top) / rect.height))
                        };
                    }
                    const videoRatio = canvas.width / canvas.height;
                    const boxRatio = rect.width / rect.height;
                    let renderW = rect.width;
                    let renderH = rect.height;
                    let offsetX = 0;
                    let offsetY = 0;
                    if (boxRatio > videoRatio) {
                        renderW = rect.height * videoRatio;
                        offsetX = (rect.width - renderW) / 2;
                    } else {
                        renderH = rect.width / videoRatio;
                        offsetY = (rect.height - renderH) / 2;
                    }
                    const normX = (clientX - rect.left - offsetX) / renderW;
                    const normY = (clientY - rect.top - offsetY) / renderH;
                    return {
                        x: Math.min(1, Math.max(0, normX)),
                        y: Math.min(1, Math.max(0, normY))
                    };
                }

                function showRipple(x, y) {
                    ripple.style.left = x + 'px';
                    ripple.style.top = y + 'px';
                    ripple.classList.add('active');
                    setTimeout(() => ripple.classList.remove('active'), 180);
                }

                function sendTouch(type, clientX, clientY, deltaX = 0, deltaY = 0) {
                    if (!touchEnabled) return;
                    const coords = normalizedCanvasCoords(clientX, clientY);
                    const xStr = coords.x.toFixed(4);
                    const yStr = coords.y.toFixed(4);
                    let url = `/api/touch?t=${type}&x=${xStr}&y=${yStr}`;
                    if (deltaX || deltaY) {
                        url += `&dx=${Math.round(deltaX)}&dy=${Math.round(deltaY)}`;
                    }
                    fetch(url, { method: 'POST', keepalive: true }).catch(() => {});
                }

                let pointerDown = false;
                let longPressTimer = null;
                let downPos = { x: 0, y: 0 };
                let queuedMove = null;
                let moveRAF = 0;

                function flushQueuedMove() {
                    moveRAF = 0;
                    if (!queuedMove) return;
                    const m = queuedMove;
                    queuedMove = null;
                    sendTouch('move', m.x, m.y);
                }

                canvas.addEventListener('pointerdown', (e) => {
                    e.preventDefault();
                    pointerDown = true;
                    downPos = { x: e.clientX, y: e.clientY };
                    showRipple(e.clientX, e.clientY);
                    sendTouch(e.button === 2 ? 'rightClick' : 'down', e.clientX, e.clientY);

                    if (longPressTimer) clearTimeout(longPressTimer);
                    longPressTimer = setTimeout(() => {
                        if (pointerDown) {
                            sendTouch('up', e.clientX, e.clientY);
                            sendTouch('rightClick', e.clientX, e.clientY);
                            pointerDown = false;
                        }
                    }, 650);
                });

                canvas.addEventListener('pointermove', (e) => {
                    if (!pointerDown && e.pointerType === 'touch') return;
                    if (longPressTimer && (Math.hypot(e.clientX - downPos.x, e.clientY - downPos.y) > 12)) {
                        clearTimeout(longPressTimer);
                        longPressTimer = null;
                    }
                    queuedMove = { x: e.clientX, y: e.clientY };
                    if (!moveRAF) {
                        moveRAF = requestAnimationFrame(flushQueuedMove);
                    }
                });

                canvas.addEventListener('pointerup', (e) => {
                    e.preventDefault();
                    if (longPressTimer) {
                        clearTimeout(longPressTimer);
                        longPressTimer = null;
                    }
                    if (moveRAF) {
                        cancelAnimationFrame(moveRAF);
                        flushQueuedMove();
                    }
                    if (!pointerDown) return;
                    pointerDown = false;
                    sendTouch('up', e.clientX, e.clientY);
                });

                canvas.addEventListener('dblclick', (e) => {
                    e.preventDefault();
                    sendTouch('doubleClick', e.clientX, e.clientY);
                });

                canvas.addEventListener('contextmenu', (e) => {
                    e.preventDefault();
                    sendTouch('rightClick', e.clientX, e.clientY);
                });

                canvas.addEventListener('wheel', (e) => {
                    e.preventDefault();
                    sendTouch('scroll', e.clientX, e.clientY, -e.deltaX, -e.deltaY);
                }, { passive: false });

                scheduleHUDAutoHide();
                pumpFrames();
            </script>
        </body>
        </html>
        """
    }
}
