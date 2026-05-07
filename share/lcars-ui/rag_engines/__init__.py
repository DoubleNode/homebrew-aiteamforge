#
#  __init__.py
#  DoubleNode Dev-Team Infrastructure (AITeamForge)
#
#  Copyright (c) 2026 - 2025 DoubleNode.com. All rights reserved.
#

"""
LCARS RAG Engine Management

Manages RAG (Retrieval-Augmented Generation) engine configurations,
lifecycle operations (install/start/stop), and health monitoring.

Supported engines:
- LightRAG: Text knowledge graph RAG (port 9621)
- Code-Graph-RAG: Source code intelligence RAG (port 9622)
- RAG-Anything: Multimodal asset RAG (port 9623)
"""

from .provider import (
    RAGEngineProvider,
    RAGEngineConfig,
    RAGEngineStatus,
    InstallProgress
)
from .manager import RAGEngineManager, get_manager

# Import engines to trigger registration
from . import engines

__all__ = [
    # Core types
    'RAGEngineProvider',
    'RAGEngineConfig',
    'RAGEngineStatus',
    'InstallProgress',
    # Manager
    'RAGEngineManager',
    'get_manager',
    # Engine implementations (accessible via rag_engines.engines)
    'engines'
]
