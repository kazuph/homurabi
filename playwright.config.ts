import path from 'node:path';
import { defineConfig } from '@playwright/test';

const audioSample = process.env.AUDIO_SAMPLE;
const fakeAudioPath = audioSample ? path.resolve(audioSample) : null;
const fakeMediaArgs = fakeAudioPath
  ? [
      '--use-fake-ui-for-media-stream',
      '--use-fake-device-for-media-stream',
      `--use-file-for-fake-audio-capture=${fakeAudioPath}`,
    ]
  : [];

export default defineConfig({
  testDir: './tests/e2e',
  fullyParallel: false,
  reporter: 'line',
  use: {
    permissions: ['microphone'],
    trace: 'on-first-retry',
    screenshot: 'only-on-failure',
    video: 'retain-on-failure',
    launchOptions: {
      args: fakeMediaArgs,
    },
  },
});
