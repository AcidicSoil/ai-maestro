import { NextRequest, NextResponse } from 'next/server'
import { agentRegistry } from '@/lib/agent'
import { initializeRagSchema } from '@/lib/cozo-schema-rag'
import { initializeSimpleSchema } from '@/lib/cozo-schema-simple'
import { backfillAgentMemory, ConversationSource } from '@/lib/memory/backfill'

interface BackfillRequestBody {
  dryRun?: boolean
  force?: boolean
  sources?: ConversationSource[]
  maxFiles?: number
}

/**
 * POST /api/agents/:id/memory/backfill
 * Backfill agent memory from historical session stores.
 */
export async function POST(
  request: NextRequest,
  { params }: { params: Promise<{ id: string }> }
) {
  try {
    const { id: agentId } = await params
    const body = await request.json().catch(() => ({} as BackfillRequestBody))

    const agent = await agentRegistry.getAgent(agentId)
    const agentDb = await agent.getDatabase()

    await initializeSimpleSchema(agentDb)
    await initializeRagSchema(agentDb)

    const report = await backfillAgentMemory(agentId, agentDb, {
      dryRun: body.dryRun !== false,
      force: body.force === true,
      sources: body.sources,
      maxFiles: body.maxFiles,
    })

    return NextResponse.json(report)
  } catch (error) {
    console.error('[Memory Backfill API] POST Error:', error)
    return NextResponse.json(
      {
        success: false,
        error: error instanceof Error ? error.message : 'Unknown error',
      },
      { status: 500 }
    )
  }
}
