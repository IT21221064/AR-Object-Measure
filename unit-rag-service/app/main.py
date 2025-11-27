from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from app.config import settings
from app.models.database import init_db
from app.routes import upload, questions, adaptive

from typing import Optional

# Initialize FastAPI app
app = FastAPI(
    title="Ganithamithura RAG Service",
    description="Adaptive learning question generation using RAG",
    version="1.0.0",
    docs_url="/docs",
    redoc_url="/redoc"
)

# Configure CORS
app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.cors_origins_list,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Include routers
app.include_router(upload.router)
app.include_router(questions.router)
app.include_router(adaptive.router)


@app.get("/documents")
async def list_all_documents(
    topic: Optional[str] = None,
    skip: int = 0,
    limit: int = 100
):
    """
    Alias endpoint for Next.js dashboard compatibility
    Returns documents in the format expected by the frontend
    """
    from app.models.database import DocumentModel
    from app.models.schemas import DocumentResponse
    
    query = {}
    if topic:
        query["topic"] = topic
    
    documents = await DocumentModel.find(query).skip(skip).limit(limit).to_list()
    
    return {
        "documents": [
            {
                "id": str(doc.id),
                "title": doc.title,
                "grade_levels": doc.grade_levels,
                "topic": doc.topic,
                "status": doc.status,
                "questions_count": doc.questions_count,
                "created_at": doc.uploaded_at.isoformat(),
                "file_path": doc.vector_db_id or ""
            }
            for doc in documents
        ]
    }


@app.delete("/documents/{document_id}")
async def delete_document_alias(document_id: str):
    """Alias for DELETE endpoint compatible with Next.js dashboard"""
    from fastapi import HTTPException
    from app.models.database import DocumentModel
    from app.services.embeddings_service import embeddings_service
    from bson import ObjectId
    
    try:
        document = await DocumentModel.find_one(DocumentModel.id == ObjectId(document_id))
    except Exception as e:
        raise HTTPException(status_code=400, detail=f"Invalid document ID: {str(e)}")
    
    if not document:
        raise HTTPException(status_code=404, detail="Document not found")
    
    # Delete from vector database if exists
    if document.vector_db_id:
        try:
            embeddings_service.delete_document(document.vector_db_id)
        except Exception as e:
            print(f"Warning: Could not delete from vector DB: {e}")
    
    # Delete from MongoDB
    await document.delete()
    
    return {"message": "Document deleted successfully", "id": document_id}


@app.get("/questions/document/{document_id}")
async def get_questions_by_document_alias(
    document_id: str,
    grade_level: Optional[int] = None,
    difficulty_level: Optional[int] = None,
    question_type: Optional[str] = None,
    topic: Optional[str] = None
):
    """Alias endpoint for Next.js dashboard - Get questions for a document"""
    from app.models.database import QuestionModel
    from app.models.schemas import QuestionResponse
    
    print(f"🔍 [ALIAS] Looking for questions with document_id: {document_id}")
    query = {"document_id": document_id}
    
    if grade_level:
        query["grade_level"] = grade_level
        print(f"🔍 [ALIAS] Filtering by grade_level: {grade_level}")
    if difficulty_level:
        query["difficulty_level"] = difficulty_level
    if question_type:
        query["question_type"] = question_type
    if topic:
        query["topic"] = topic
        print(f"🔍 [ALIAS] Filtering by topic: {topic}")
    
    print(f"🔍 [ALIAS] Query: {query}")
    questions = await QuestionModel.find(query).to_list()
    print(f"📊 [ALIAS] Found {len(questions)} questions")
    
    # Return empty list instead of 404 if no questions found
    if not questions:
        print(f"⚠️ [ALIAS] No questions found for document {document_id}")
        return []
    
    # Group questions by topic and grade for better organization
    questions_by_topic_grade = {}
    for q in questions:
        key = f"{q.topic or 'Unknown'}_{q.grade_level}"
        if key not in questions_by_topic_grade:
            questions_by_topic_grade[key] = []
        questions_by_topic_grade[key].append(q)
    
    print(f"📋 [ALIAS] Questions grouped: {[(k, len(v)) for k, v in questions_by_topic_grade.items()]}")
    
    return [
        QuestionResponse(
            id=str(q.id),
            question_text=q.question_text,
            question_type=q.question_type,
            options=q.options,
            grade_level=q.grade_level,
            difficulty_level=q.difficulty_level,
            bloom_level=q.bloom_level,
            concepts=q.concepts,
            explanation=q.explanation,
            hints=q.hints
        )
        for q in questions
    ]


@app.on_event("startup")
async def startup_event():
    """Initialize database on startup"""
    await init_db()
    print(f"✅ Server running on {settings.host}:{settings.port}")
    print(f"✅ Environment: {settings.environment}")
    print(f"✅ Docs available at: http://{settings.host}:{settings.port}/docs")


@app.get("/")
async def root():
    """Root endpoint - health check"""
    return {
        "service": "Ganithamithura RAG Service",
        "status": "running",
        "version": "1.0.0",
        "environment": settings.environment
    }


@app.get("/health")
async def health_check():
    """Health check endpoint"""
    from app.services.embeddings_service import embeddings_service
    
    try:
        # Check vector database
        stats = embeddings_service.get_collection_stats()
        
        return {
            "status": "healthy",
            "database": "connected",
            "vector_store": stats
        }
    except Exception as e:
        return {
            "status": "unhealthy",
            "error": str(e)
        }


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(
        "app.main:app",
        host=settings.host,
        port=settings.port,
        reload=settings.debug
    )
