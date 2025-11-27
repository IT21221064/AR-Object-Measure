from pydantic_settings import BaseSettings
from typing import List


class Settings(BaseSettings):
    # Environment
    environment: str = "development"
    
    # OpenAI
    openai_api_key: str
    openai_model: str = "gpt-4o-mini"
    
    # MongoDB
    mongodb_url: str = "mongodb://localhost:27017"
    mongodb_db_name: str = "ganithamithura_rag"
    
    # ChromaDB
    chroma_persist_directory: str = "./vectorstore"
    chroma_collection_name: str = "ganithamithura_documents"
    
    # Server
    host: str = "0.0.0.0"
    port: int = 8000
    debug: bool = True
    
    # File Upload
    max_upload_size: int = 10485760  # 10MB
    allowed_extensions_str: str = "pdf,docx,txt"
    
    # RAG
    chunk_size: int = 512
    chunk_overlap: int = 50
    embedding_model: str = "text-embedding-ada-002"
    top_k_retrieval: int = 5
    
    # Question Generation
    questions_per_grade: int = 10
    max_generation_retries: int = 3
    
    # Adaptive Learning
    initial_ability_score: float = 0.0
    min_difficulty: int = 1
    max_difficulty: int = 5
    target_success_rate: float = 0.7
    learning_rate: float = 0.3
    
    # CORS
    cors_origins: str = "http://localhost:3000,http://localhost:3001"
    
    class Config:
        env_file = ".env"
        case_sensitive = False
        extra = "ignore"  # Ignore extra fields from .env
    
    @property
    def allowed_extensions(self) -> List[str]:
        return [ext.strip() for ext in self.allowed_extensions_str.split(",")]
    
    @property
    def cors_origins_list(self) -> List[str]:
        return [origin.strip() for origin in self.cors_origins.split(",")]


settings = Settings()
