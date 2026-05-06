import { expect, test } from '@playwright/test';

const aiChatUrl = process.env.AI_CHAT_URL;
const aiTranscribeChatUrl = process.env.AI_TRANSCRIBE_CHAT_URL;
const aiVoiceChatUrl = process.env.AI_VOICE_CHAT_URL;
const aiVoiceChatToken = process.env.AI_VOICE_CHAT_TOKEN;
const audioSample = process.env.AUDIO_SAMPLE;
const artifactDir = process.env.ARTIFACT_DIR;

function screenshotPath(name: string) {
  return artifactDir ? `${artifactDir}/${name}.png` : undefined;
}

function withToken(url: string, token?: string) {
  if (!token) return url;
  const parsed = new URL(url);
  parsed.searchParams.set('token', token);
  return parsed.toString();
}

test.describe('Workers AI examples', () => {
  test.skip(
    !aiChatUrl || !aiTranscribeChatUrl || !aiVoiceChatUrl || !audioSample,
    'Set AI_CHAT_URL, AI_TRANSCRIBE_CHAT_URL, AI_VOICE_CHAT_URL, and AUDIO_SAMPLE.'
  );

  test('ai-chat returns a visible reply', async ({ page }) => {
    await page.goto(aiChatUrl!);
    await page.waitForLoadState('networkidle');

    await page.getByLabel('Message').fill('こんにちは。短くあいさつして。');
    await page.getByRole('button', { name: /send to kimi/i }).click();

    await expect(page.getByRole('heading', { name: 'Reply' })).toBeVisible();
    await expect(page.locator('pre').last()).not.toContainText(
      'The model returned an empty reply.'
    );

    const path = screenshotPath('ai-chat');
    if (path) await page.screenshot({ path, fullPage: true });
  });

  test('ai-transcribe-chat shows transcript and reply', async ({ page }) => {
    await page.goto(aiTranscribeChatUrl!);
    await page.waitForLoadState('networkidle');

    await page.getByLabel('Audio clip').setInputFiles(audioSample!);
    await page.getByLabel('Whisper language hint').selectOption('ja');
    await page.getByRole('button', { name: /transcribe and reply/i }).click();

    await expect(page.getByRole('heading', { name: 'Transcript' })).toBeVisible();
    await expect(page.getByRole('heading', { name: 'Kimi reply' })).toBeVisible();
    await expect(page.locator('pre').nth(1)).not.toContainText(
      'The model returned an empty reply.'
    );

    const path = screenshotPath('ai-transcribe-chat');
    if (path) await page.screenshot({ path, fullPage: true });
  });

  test('ai-voice-chat embeds playable audio', async ({ page }) => {
    if (aiVoiceChatToken) {
      const locked = await page.context().request.get(aiVoiceChatUrl!);
      expect(locked.status()).toBe(404);
    }

    await page.goto(withToken(aiVoiceChatUrl!, aiVoiceChatToken));
    await page.waitForLoadState('networkidle');

    await page.getByLabel('Audio clip').setInputFiles(audioSample!);
    await page.getByLabel('Whisper language hint').selectOption('ja');
    await page.getByLabel('Aura speaker').selectOption('luna');
    await page.getByRole('button', { name: /transcribe, reply, and speak/i }).click();

    await expect(page.getByRole('heading', { name: 'Transcript' })).toBeVisible();
    await expect(page.getByRole('heading', { name: 'Kimi reply' })).toBeVisible();

    const audio = page.locator('audio');
    await expect(audio).toBeVisible();
    await expect(page.locator('pre').nth(1)).not.toContainText(
      'The model returned an empty reply.'
    );
    await expect(page.getByRole('heading', { name: 'Spoken script' })).toBeVisible();

    const spokenScript = (await page.locator('pre').nth(2).textContent()) || '';
    expect(spokenScript).toMatch(/^[\x20-\x7E\s]+$/);
    expect(spokenScript).not.toMatch(/[ぁ-んァ-ヶ一-龠々ー]/);

    const src = await audio.getAttribute('src');
    expect(src).toContain('data:audio/mpeg;base64,');

    const path = screenshotPath('ai-voice-chat');
    if (path) await page.screenshot({ path, fullPage: true });
  });
});
