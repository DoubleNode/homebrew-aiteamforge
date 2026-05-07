#
#  __init__.py
#  DoubleNode Dev-Team Infrastructure (AITeamForge)
#
#  Copyright (c) 2026 - 2025 DoubleNode.com. All rights reserved.
#

"""
RAG Engine Implementations

Concrete providers for each supported RAG engine type.
Importing this module registers all engines with the RAGEngineManager.
"""

from .lightrag_engine import LightRAGEngine
from .code_graph_rag_engine import CodeGraphRAGEngine
from .rag_anything_engine import RAGAnythingEngine
from ..manager import RAGEngineManager

# Register all engine types with the manager on import
RAGEngineManager.register_engine('lightrag', LightRAGEngine)
RAGEngineManager.register_engine('code-graph-rag', CodeGraphRAGEngine)
RAGEngineManager.register_engine('rag-anything', RAGAnythingEngine)

__all__ = [
    'LightRAGEngine',
    'CodeGraphRAGEngine',
    'RAGAnythingEngine'
]
