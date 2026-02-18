import * as fs from 'fs'
import * as os from 'os'
import * as path from 'path'
import { AgentDatabase } from '@/lib/cozo-db'
import { getAgent, getAgentBySession } from '@/lib/agent-registry'
import { getSelfHost } from '@/lib/hosts-config'
import { getConversations, getProjects, recordConversation, recordProject, recordSession } from '@/lib/cozo-schema-simple'

export type ConversationSource = 'claude' | 'codex'

export interface DiscoveredConversation {
  source: ConversationSource
  jsonlFile: string
  cwd: string | null
  sessionId: string | null
  firstMessageAt: number | null
  lastMessageAt: number | null
  messageCount: number
  firstUserMessage: string | null
  modelNames: string | null
  gitBranch: string | null
  cliVersion: string | null
}

export interface BackfillRequest {
  sources?: ConversationSource[]
  dryRun?: boolean
  maxFiles?: number
  force?: boolean
}

export interface SourceStats {
  discovered: number
  matched: number
  unmapped: number
  existing: number
  inserted: number
}

export interface BackfillReport {
  success: boolean
  agent_id: string
  mode: 'dry-run' | 'apply'
  sources: Record<ConversationSource, SourceStats>
  total_discovered: number
  total_matched: number
  total_unmapped: number
  total_existing: number
  total_inserted: number
  max_files_applied: number
  truncated: boolean
  working_directories: string[]
  active_sessions_seen: number
  unmapped_examples: string[]
  existing_examples: string[]
  inserted_examples: string[]
}

interface SessionDiscoveryResult {
  activeSessionsSeen: number
  workingDirectories: Set<string>
}

const MAX_EXAMPLES = 20

function parseTimestamp(raw: unknown): number | null {
  if (typeof raw !== 'string' || raw.length === 0) {
    return null
  }
  const ts = new Date(raw).getTime()
  if (Number.isNaN(ts)) {
    return null
  }
  return ts
}

function truncateText(raw: string | null, maxLength: number = 100): string | null {
  if (!raw) return null
  const normalized = raw.replace(/[\n\r\t]+/g, ' ').trim()
  if (!normalized) return null
  return normalized.length > maxLength ? normalized.substring(0, maxLength) : normalized
}

function toDisplayModel(model: string): string {
  const normalized = model.toLowerCase()
  if (normalized.includes('sonnet')) return 'Sonnet 4.5'
  if (normalized.includes('haiku')) return 'Haiku 4.5'
  if (normalized.includes('opus')) return 'Opus 4.5'
  return model
}

function parseUserContent(payload: unknown): string | null {
  if (!payload || typeof payload !== 'object') return null
  const content = (payload as Record<string, unknown>).content
  if (typeof content === 'string') {
    return truncateText(content)
  }
  if (Array.isArray(content)) {
    const chunks = content
      .map((entry) => {
        if (!entry || typeof entry !== 'object') return ''
        const item = entry as Record<string, unknown>
        if (item.type === 'input_text' && typeof item.text === 'string') {
          return item.text
        }
        if (item.type === 'text' && typeof item.text === 'string') {
          return item.text
        }
        return ''
      })
      .filter(Boolean)
    return truncateText(chunks.join(' '))
  }
  return null
}

export function normalizePathForMatch(input: string): string {
  let normalized = path.normalize(input.trim())
  if (normalized.length > 1 && normalized.endsWith(path.sep)) {
    normalized = normalized.slice(0, -1)
  }
  normalized = normalized.replace(/\\/g, '/')
  if (normalized.length > 1 && normalized.endsWith('/')) {
    normalized = normalized.slice(0, -1)
  }
  const windowsDrive = normalized.match(/^([A-Za-z]):\//)
  if (windowsDrive) {
    normalized = `${windowsDrive[1].toLowerCase()}:${normalized.slice(2)}`
  }
  return normalized
}

function findJsonlFiles(rootDir: string): string[] {
  const files: string[] = []
  if (!fs.existsSync(rootDir)) {
    return files
  }
  const stack = [rootDir]
  while (stack.length > 0) {
    const current = stack.pop()!
    let items: string[] = []
    try {
      items = fs.readdirSync(current)
    } catch {
      continue
    }
    for (const item of items) {
      const fullPath = path.join(current, item)
      try {
        const stats = fs.statSync(fullPath)
        if (stats.isDirectory()) {
          stack.push(fullPath)
        } else if (item.endsWith('.jsonl')) {
          files.push(fullPath)
        }
      } catch {
        // ignore unreadable entries
      }
    }
  }
  return files
}

export function extractConversationFromClaudeLines(
  lines: string[],
  jsonlFile: string
): DiscoveredConversation {
  let sessionId: string | null = null
  let cwd: string | null = null
  let firstUserMessage: string | null = null
  let gitBranch: string | null = null
  let cliVersion: string | null = null
  let firstMessageAt: number | null = null
  let lastMessageAt: number | null = null
  const modelSet = new Set<string>()

  const metadataLines = lines.slice(0, 80)
  for (const line of metadataLines) {
    try {
      const message = JSON.parse(line) as Record<string, unknown>
      if (!sessionId && typeof message.sessionId === 'string') sessionId = message.sessionId
      if (!cwd && typeof message.cwd === 'string') cwd = message.cwd
      if (!gitBranch && typeof message.gitBranch === 'string') gitBranch = message.gitBranch
      if (!cliVersion && typeof message.version === 'string') cliVersion = message.version

      const parsedTs = parseTimestamp(message.timestamp)
      if (parsedTs !== null && (firstMessageAt === null || parsedTs < firstMessageAt)) {
        firstMessageAt = parsedTs
      }

      if (!firstUserMessage && message.type === 'user') {
        const msg = message.message as Record<string, unknown> | undefined
        if (msg && typeof msg.content === 'string') {
          firstUserMessage = truncateText(msg.content)
        }
      }

      if (message.type === 'assistant') {
        const msg = message.message as Record<string, unknown> | undefined
        if (msg && typeof msg.model === 'string') {
          modelSet.add(toDisplayModel(msg.model))
        }
      }
    } catch {
      // ignore malformed lines
    }
  }

  for (let i = lines.length - 1; i >= Math.max(0, lines.length - 50); i--) {
    try {
      const message = JSON.parse(lines[i]) as Record<string, unknown>
      const parsedTs = parseTimestamp(message.timestamp)
      if (parsedTs !== null) {
        lastMessageAt = parsedTs
        break
      }
    } catch {
      // ignore malformed lines
    }
  }

  return {
    source: 'claude',
    jsonlFile,
    cwd,
    sessionId,
    firstMessageAt,
    lastMessageAt,
    messageCount: lines.length,
    firstUserMessage,
    modelNames: modelSet.size > 0 ? Array.from(modelSet).join(', ') : null,
    gitBranch,
    cliVersion,
  }
}

export function extractConversationFromCodexLines(
  lines: string[],
  jsonlFile: string
): DiscoveredConversation {
  let sessionId: string | null = null
  let cwd: string | null = null
  let firstUserMessage: string | null = null
  let gitBranch: string | null = null
  let cliVersion: string | null = null
  let firstMessageAt: number | null = null
  let lastMessageAt: number | null = null
  const modelSet = new Set<string>()

  for (const line of lines) {
    try {
      const event = JSON.parse(line) as Record<string, unknown>
      const eventTs = parseTimestamp(event.timestamp)
      if (eventTs !== null && (firstMessageAt === null || eventTs < firstMessageAt)) {
        firstMessageAt = eventTs
      }
      if (eventTs !== null && (lastMessageAt === null || eventTs > lastMessageAt)) {
        lastMessageAt = eventTs
      }

      const type = event.type
      if (type === 'session_meta') {
        const payload = event.payload as Record<string, unknown> | undefined
        if (payload) {
          if (!sessionId && typeof payload.id === 'string') sessionId = payload.id
          if (!cwd && typeof payload.cwd === 'string') cwd = payload.cwd
          if (!cliVersion && typeof payload.cli_version === 'string') cliVersion = payload.cli_version
          const git = payload.git as Record<string, unknown> | undefined
          if (!gitBranch && git && typeof git.branch === 'string') {
            gitBranch = git.branch
          }
        }
      } else if (type === 'turn_context') {
        const payload = event.payload as Record<string, unknown> | undefined
        if (payload) {
          if (!cwd && typeof payload.cwd === 'string') cwd = payload.cwd
          if (typeof payload.model === 'string') {
            modelSet.add(payload.model)
          }
        }
      } else if (type === 'response_item') {
        const payload = event.payload as Record<string, unknown> | undefined
        if (!payload || payload.type !== 'message' || payload.role !== 'user') {
          continue
        }
        if (!firstUserMessage) {
          firstUserMessage = parseUserContent(payload)
        }
      } else if (type === 'event_msg') {
        const payload = event.payload as Record<string, unknown> | undefined
        if (!payload) continue
        if (!firstUserMessage && payload.type === 'user_message' && typeof payload.message === 'string') {
          firstUserMessage = truncateText(payload.message)
        }
      }
    } catch {
      // ignore malformed lines
    }
  }

  return {
    source: 'codex',
    jsonlFile,
    cwd,
    sessionId,
    firstMessageAt,
    lastMessageAt,
    messageCount: lines.length,
    firstUserMessage,
    modelNames: modelSet.size > 0 ? Array.from(modelSet).join(', ') : null,
    gitBranch,
    cliVersion,
  }
}

function discoverConversationsFromFiles(
  files: string[],
  source: ConversationSource
): DiscoveredConversation[] {
  const discovered: DiscoveredConversation[] = []
  for (const file of files) {
    let raw = ''
    try {
      raw = fs.readFileSync(file, 'utf-8')
    } catch {
      continue
    }
    const lines = raw.split('\n').filter((line) => line.trim().length > 0)
    if (lines.length === 0) continue

    const parsed = source === 'claude'
      ? extractConversationFromClaudeLines(lines, file)
      : extractConversationFromCodexLines(lines, file)
    discovered.push(parsed)
  }
  return discovered
}

function discoverConversations(sources: ConversationSource[]): DiscoveredConversation[] {
  const home = os.homedir()
  const conversations: DiscoveredConversation[] = []
  const sourceSet = new Set(sources)

  if (sourceSet.has('claude')) {
    const claudeRoot = path.join(home, '.claude', 'projects')
    const claudeFiles = findJsonlFiles(claudeRoot)
    conversations.push(...discoverConversationsFromFiles(claudeFiles, 'claude'))
  }
  if (sourceSet.has('codex')) {
    const codexRoot = path.join(home, '.codex', 'sessions')
    const codexFiles = findJsonlFiles(codexRoot)
    conversations.push(...discoverConversationsFromFiles(codexFiles, 'codex'))
  }

  return conversations
}

async function fetchWorkingDirectoriesForAgent(
  agentId: string,
  agentDb: AgentDatabase,
  applyWrites: boolean
): Promise<SessionDiscoveryResult> {
  const workingDirectories = new Set<string>()
  const registryAgent = getAgent(agentId) || getAgentBySession(agentId)
  if (registryAgent) {
    const baseWd = registryAgent.workingDirectory || registryAgent.sessions?.[0]?.workingDirectory
    const prefWd = registryAgent.preferences?.defaultWorkingDirectory
    if (baseWd) workingDirectories.add(normalizePathForMatch(baseWd))
    if (prefWd) workingDirectories.add(normalizePathForMatch(prefWd))
  }

  let activeSessionsSeen = 0
  try {
    const selfHost = getSelfHost()
    const response = await fetch(`${selfHost.url}/api/sessions`)
    if (!response.ok) {
      return { activeSessionsSeen, workingDirectories }
    }
    const sessionsData = await response.json()
    for (const session of sessionsData.sessions || []) {
      if (session.agentId !== agentId) continue
      activeSessionsSeen++
      if (session.workingDirectory) {
        workingDirectories.add(normalizePathForMatch(session.workingDirectory))
      }
      if (applyWrites) {
        await recordSession(agentDb, {
          session_id: session.id,
          session_name: session.name,
          agent_id: agentId,
          working_directory: session.workingDirectory,
          started_at: new Date(session.createdAt).getTime(),
          status: session.status,
        })
      }
    }
  } catch {
    // Session listing is best effort; backfill can still run from registry WD.
  }

  return { activeSessionsSeen, workingDirectories }
}

async function getExistingConversationFiles(agentDb: AgentDatabase): Promise<Set<string>> {
  const existingFiles = new Set<string>()
  const projects = await getProjects(agentDb)
  for (const project of projects.rows || []) {
    const projectPath = project[0] as string
    const conversations = await getConversations(agentDb, projectPath)
    for (const row of conversations.rows || []) {
      if (row[0]) {
        existingFiles.add(row[0] as string)
      }
    }
  }
  return existingFiles
}

function emptySourceStats(): SourceStats {
  return {
    discovered: 0,
    matched: 0,
    unmapped: 0,
    existing: 0,
    inserted: 0,
  }
}

function emptyReport(agentId: string, dryRun: boolean, maxFilesApplied: number): BackfillReport {
  return {
    success: true,
    agent_id: agentId,
    mode: dryRun ? 'dry-run' : 'apply',
    sources: {
      claude: emptySourceStats(),
      codex: emptySourceStats(),
    },
    total_discovered: 0,
    total_matched: 0,
    total_unmapped: 0,
    total_existing: 0,
    total_inserted: 0,
    max_files_applied: maxFilesApplied,
    truncated: false,
    working_directories: [],
    active_sessions_seen: 0,
    unmapped_examples: [],
    existing_examples: [],
    inserted_examples: [],
  }
}

function pushExample(target: string[], value: string) {
  if (target.length >= MAX_EXAMPLES) return
  target.push(value)
}

export async function backfillAgentMemory(
  agentId: string,
  agentDb: AgentDatabase,
  request: BackfillRequest = {}
): Promise<BackfillReport> {
  const sources: ConversationSource[] = request.sources && request.sources.length > 0
    ? request.sources
    : ['claude', 'codex']
  const dryRun = request.dryRun === true
  const maxFiles = typeof request.maxFiles === 'number' && request.maxFiles > 0
    ? request.maxFiles
    : 5000

  const report = emptyReport(agentId, dryRun, maxFiles)
  const { activeSessionsSeen, workingDirectories } = await fetchWorkingDirectoriesForAgent(agentId, agentDb, !dryRun)
  report.active_sessions_seen = activeSessionsSeen
  report.working_directories = Array.from(workingDirectories.values())

  const discoveredAll = discoverConversations(sources)
  for (const item of discoveredAll) {
    report.sources[item.source].discovered++
  }
  report.total_discovered = discoveredAll.length

  let discovered = discoveredAll
  if (discovered.length > maxFiles) {
    report.truncated = true
    discovered = discovered.slice(0, maxFiles)
  }

  const workingDirectorySet = new Set(report.working_directories)
  const matched: DiscoveredConversation[] = []
  for (const item of discovered) {
    const normalizedCwd = item.cwd ? normalizePathForMatch(item.cwd) : null
    if (!normalizedCwd || !workingDirectorySet.has(normalizedCwd)) {
      report.sources[item.source].unmapped++
      report.total_unmapped++
      pushExample(report.unmapped_examples, item.jsonlFile)
      continue
    }
    report.sources[item.source].matched++
    report.total_matched++
    matched.push({ ...item, cwd: normalizedCwd })
  }

  const existingFiles = await getExistingConversationFiles(agentDb)

  for (const item of matched) {
    if (existingFiles.has(item.jsonlFile)) {
      report.sources[item.source].existing++
      report.total_existing++
      pushExample(report.existing_examples, item.jsonlFile)
      continue
    }

    if (!dryRun && item.cwd) {
      await recordProject(agentDb, {
        project_path: item.cwd,
        project_name: path.basename(item.cwd) || 'unknown',
        claude_dir: path.dirname(item.jsonlFile),
      })
      await recordConversation(agentDb, {
        jsonl_file: item.jsonlFile,
        project_path: item.cwd,
        session_id: item.sessionId || 'unknown',
        message_count: item.messageCount,
        first_message_at: item.firstMessageAt || undefined,
        last_message_at: item.lastMessageAt || undefined,
        first_user_message: item.firstUserMessage || undefined,
        model_names: item.modelNames || undefined,
        git_branch: item.gitBranch || undefined,
        claude_version: item.cliVersion || undefined,
      })
    }

    report.sources[item.source].inserted++
    report.total_inserted++
    pushExample(report.inserted_examples, item.jsonlFile)
  }

  return report
}
