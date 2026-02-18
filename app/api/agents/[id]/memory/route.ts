import { NextRequest, NextResponse } from 'next/server'
import { agentRegistry } from '@/lib/agent'
import {
  initializeSimpleSchema,
  getSessions,
  getProjects,
  getConversations
} from '@/lib/cozo-schema-simple'
import { initializeRagSchema } from '@/lib/cozo-schema-rag'
import { backfillAgentMemory, ConversationSource } from '@/lib/memory/backfill'

/**
 * GET /api/agents/:id/memory
 * Get agent's memory (sessions and projects)
 */
export async function GET(
  request: NextRequest,
  { params }: { params: Promise<{ id: string }> }
) {
  try {
    const { id: agentId } = await params

    // Get or create agent (will initialize with subconscious if first time)
    const agent = await agentRegistry.getAgent(agentId)
    const agentDb = await agent.getDatabase()

    // Get sessions and projects
    const sessions = await getSessions(agentDb, agentId)
    const projects = await getProjects(agentDb)

    // Get conversations for each project
    const projectsWithConversations = []
    for (const project of (projects.rows || [])) {
      const projectPath = project[0] // First column is project_path
      const conversations = await getConversations(agentDb, projectPath)
      projectsWithConversations.push({
        project: project,
        conversations: conversations.rows || []
      })
    }

    // NOTE: Agent's subconscious now handles background indexing automatically
    // No need to manually trigger - each agent maintains its own memory

    return NextResponse.json({
      success: true,
      agent_id: agentId,
      sessions: sessions.rows || [],
      projects: projectsWithConversations
    })
  } catch (error) {
    console.error('[Memory API] GET Error:', error)
    return NextResponse.json(
      {
        success: false,
        error: error instanceof Error ? error.message : 'Unknown error'
      },
      { status: 500 }
    )
  }
}

interface MemoryInitRequest {
  populateFromSessions?: boolean
  force?: boolean
  dryRun?: boolean
  sources?: ConversationSource[]
  maxFiles?: number
}

/**
 * POST /api/agents/:id/memory
 * Initialize schema and optionally populate from current tmux sessions
 */
export async function POST(
  request: NextRequest,
  { params }: { params: Promise<{ id: string }> }
) {
  try {
    const { id: agentId } = await params
    const body = await request.json().catch(() => ({} as MemoryInitRequest))

    // Get or create agent (will initialize with subconscious if first time)
    const agent = await agentRegistry.getAgent(agentId)
    const agentDb = await agent.getDatabase()

    // Initialize schema (simple + RAG extensions)
    await initializeSimpleSchema(agentDb)
    await initializeRagSchema(agentDb)

    // If requested, populate from historical conversations
    if (body.populateFromSessions) {
      const dryRun = body.dryRun === true

      // Check if database is already populated to avoid expensive rescanning.
      // Skip this protection for dry-runs and force mode.
      if (!body.force && !dryRun) {
        const existingProjects = await getProjects(agentDb)
        if (existingProjects.rows && existingProjects.rows.length > 0) {
          console.log(`[Memory API] Database already populated with ${existingProjects.rows.length} projects. Skipping population scan. Use force=true to re-populate.`)
          return NextResponse.json({
            success: true,
            agent_id: agentId,
            message: 'Memory schema initialized (already populated)',
            skipped_population: true
          })
        }
      } else if (body.force) {
        console.log(`[Memory API] Force flag set - re-populating database`)
      }

      const report = await backfillAgentMemory(agentId, agentDb, {
        dryRun,
        force: body.force === true,
        sources: body.sources,
        maxFiles: body.maxFiles,
      })

      console.log('[Memory API] ✅ Backfill complete', {
        mode: report.mode,
        total_discovered: report.total_discovered,
        total_inserted: report.total_inserted,
      })

      return NextResponse.json({
        success: true,
        agent_id: agentId,
        message: dryRun ? 'Memory backfill dry-run complete' : 'Memory initialized and populated from historical sessions',
        report,
      })
    }

    // NOTE: Agent's subconscious is already running and will maintain memory automatically

    return NextResponse.json({
      success: true,
      agent_id: agentId,
      message: 'Memory initialized' + (body.populateFromSessions ? ' and populated from sessions' : '')
    })
  } catch (error) {
    console.error('[Memory API] POST Error:', error)
    return NextResponse.json(
      {
        success: false,
        error: error instanceof Error ? error.message : 'Unknown error'
      },
      { status: 500 }
    )
  }
}
