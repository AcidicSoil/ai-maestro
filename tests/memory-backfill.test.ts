import { describe, it, expect } from 'vitest'
import {
  extractConversationFromCodexLines,
  extractConversationFromClaudeLines,
  normalizePathForMatch,
} from '@/lib/memory/backfill'

describe('normalizePathForMatch', () => {
  it('normalizes trailing separators', () => {
    expect(normalizePathForMatch('/home/user/projects/app/')).toBe('/home/user/projects/app')
  })

  it('normalizes windows slashes and drive case', () => {
    expect(normalizePathForMatch('C:\\Users\\test\\repo\\')).toBe('c:/Users/test/repo')
  })
})

describe('extractConversationFromCodexLines', () => {
  it('extracts codex metadata and first user content', () => {
    const lines = [
      JSON.stringify({
        timestamp: '2025-11-22T20:05:51.892Z',
        type: 'session_meta',
        payload: {
          id: 'abc-session',
          cwd: '/home/user/projects/sample',
          cli_version: '0.63.0',
          git: { branch: 'main' },
        },
      }),
      JSON.stringify({
        timestamp: '2025-11-22T20:05:52.000Z',
        type: 'turn_context',
        payload: {
          model: 'gpt-5-codex',
        },
      }),
      JSON.stringify({
        timestamp: '2025-11-22T20:05:53.000Z',
        type: 'response_item',
        payload: {
          type: 'message',
          role: 'user',
          content: [{ type: 'input_text', text: 'Implement API and tests' }],
        },
      }),
    ]

    const parsed = extractConversationFromCodexLines(lines, '/tmp/codex-session.jsonl')

    expect(parsed.source).toBe('codex')
    expect(parsed.sessionId).toBe('abc-session')
    expect(parsed.cwd).toBe('/home/user/projects/sample')
    expect(parsed.gitBranch).toBe('main')
    expect(parsed.cliVersion).toBe('0.63.0')
    expect(parsed.modelNames).toContain('gpt-5-codex')
    expect(parsed.firstUserMessage).toContain('Implement API and tests')
    expect(parsed.messageCount).toBe(3)
    expect(parsed.firstMessageAt).not.toBeNull()
    expect(parsed.lastMessageAt).not.toBeNull()
  })
})

describe('extractConversationFromClaudeLines', () => {
  it('extracts claude-style metadata and model mapping', () => {
    const lines = [
      JSON.stringify({
        timestamp: '2025-10-01T17:11:14.306Z',
        sessionId: 'claude-session',
        cwd: '/home/user/projects/rpg_tool',
        gitBranch: 'feature/backfill',
        version: '0.42.0',
        type: 'user',
        message: {
          content: 'Analyze complexity of tasks with research',
        },
      }),
      JSON.stringify({
        timestamp: '2025-10-01T17:11:20.000Z',
        type: 'assistant',
        message: {
          model: 'claude-sonnet-4-5-20250929',
        },
      }),
    ]

    const parsed = extractConversationFromClaudeLines(lines, '/tmp/claude-session.jsonl')

    expect(parsed.source).toBe('claude')
    expect(parsed.sessionId).toBe('claude-session')
    expect(parsed.cwd).toBe('/home/user/projects/rpg_tool')
    expect(parsed.gitBranch).toBe('feature/backfill')
    expect(parsed.cliVersion).toBe('0.42.0')
    expect(parsed.firstUserMessage).toContain('Analyze complexity')
    expect(parsed.modelNames).toContain('Sonnet 4.5')
    expect(parsed.messageCount).toBe(2)
  })
})
