#!/usr/bin/env node
import { renderSlides } from './headless-renderer.mjs';

// k3s fixes these in the image ENV and serves the daemon on 7456; this stack
// puts the nginx sidecar on 7456 and the daemon on 7457, so they are read from
// the environment rather than hard-coded. The launcher exports both, and the
// loopback default is the security floor if it ever runs without one.
const host = process.env.OD_BIND_HOST || '127.0.0.1';
const port = Number(process.env.OD_PORT) || 7457;
// OpenDesign 0.24.1's startServer({ returnServer: true }).shutdown only stops
// daemon runs; it neither closes the HTTP server nor ends background timers, so
// the process must close the server itself and exit explicitly. With one process
// per container the time bound has to live here too, or every stop burns the
// whole stop timeout and ends in SIGKILL (exit 137).
const SHUTDOWN_GRACE_MS = 10_000;
let started;
let stopping = false;

async function stop(signal) {
  if (stopping) return;
  stopping = true;
  console.info(`[woow-opendesign] ${signal} received; stopping OpenDesign`);
  // Unref'd: it never keeps a drained event loop alive, but it still fires if
  // something else is holding the loop open past the grace window.
  const forced = setTimeout(() => {
    console.warn(`[woow-opendesign] shutdown exceeded ${SHUTDOWN_GRACE_MS}ms; exiting`);
    process.exit(typeof process.exitCode === 'number' ? process.exitCode : 0);
  }, SHUTDOWN_GRACE_MS);
  forced.unref?.();
  try {
    await started?.shutdown?.();
    await new Promise((resolve) => {
      const server = started?.server;
      if (!server || !server.listening) {
        resolve();
        return;
      }
      server.close(() => resolve());
      server.closeAllConnections?.();
    });
  } catch (error) {
    console.error('[woow-opendesign] shutdown error', error);
  }
}

function stopAndExit(signal) {
  void stop(signal).finally(() => process.exit(process.exitCode ?? 0));
}

try {
  const { startServer } = await import('/app/apps/daemon/dist/server.js');
  started = await startServer({
    host,
    port,
    returnServer: true,
    desktopSlideRenderer: renderSlides,
    desktopArtifactExporter: null,
  });
  console.info(`[woow-opendesign] OpenDesign ${started.url} with Playwright export renderer`);

  process.once('SIGTERM', () => stopAndExit('SIGTERM'));
  process.once('SIGINT', () => stopAndExit('SIGINT'));
  await new Promise((resolve, reject) => {
    started.server.once('close', resolve);
    started.server.once('error', reject);
  });
  // The server closed without a stop signal: a required process ended.
  if (!stopping) process.exitCode = 1;
} catch (error) {
  console.error('[woow-opendesign] failed to start', error);
  process.exitCode = 1;
} finally {
  if (!stopping) stopAndExit('exit');
}
