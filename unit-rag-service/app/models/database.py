"""
Database models for the RAG service using Beanie ODM (MongoDB).
"""

from beanie import Document, Indexed, init_beanie
from pydantic import Field
from typing import List, Optional, Dict, Any
from datetime import datetime
from motor.motor_asyncio import AsyncIOMotorClient
from app.config import settings


# MongoDB Models using Beanie ODM
class DocumentModel(Document):
    """Document uploaded by teachers"""
    title: str = Field(..., max_length=255)
    content: Optional[str] = None
    grade_levels: List[int] = Field(default_factory=list)
    topic: Optional[str] = Field(None, max_length=100)
    uploaded_by: Optional[str] = Field(None, max_length=100)
    uploaded_at: datetime = Field(default_factory=datetime.utcnow)
    status: str = Field(default="processing")  # processing, completed, failed
    vector_db_id: Optional[str] = Field(None, max_length=100)
    questions_count: int = Field(default=0)
    
    class Settings:
        name = "documents"
        indexes = [
            "status",
            "topic",
            "uploaded_by",
        ]


class QuestionModel(Document):
    """Questions generated from documents"""
    document_id: Optional[str] = None  # MongoDB ObjectId as string
    unit_id: Optional[str] = None  # For linking to Flutter app units (e.g., "unit_length_1")
    topic: Optional[str] = None  # Length, Area, Capacity, Weight
    question_text: str
    question_type: str  # mcq, short_answer, true_false
    correct_answer: str
    options: Optional[List[str]] = None  # For MCQ options
    grade_level: int
    difficulty_level: int = Field(ge=1, le=5)  # 1-5
    bloom_level: Optional[str] = None  # remember, understand, apply, analyze
    concepts: List[str] = Field(default_factory=list)  # Tags for concepts covered
    explanation: Optional[str] = None
    hints: List[str] = Field(default_factory=list)
    created_at: datetime = Field(default_factory=datetime.utcnow)
    
    class Settings:
        name = "questions"
        indexes = [
            "document_id",
            "unit_id",
            "topic",
            "grade_level",
            "difficulty_level",
            "question_type",
            [("grade_level", 1), ("difficulty_level", 1)],  # Compound index
            [("unit_id", 1), ("difficulty_level", 1)],  # Compound index for adaptive
        ]


class StudentAnswerModel(Document):
    """Student answer history"""
    student_id: Indexed(str)  # Indexed for fast lookups
    question_id: str  # MongoDB ObjectId as string
    unit_id: int
    answer_given: Optional[str] = None
    is_correct: bool
    time_taken: Optional[int] = None  # seconds
    difficulty_at_attempt: int
    answered_at: datetime = Field(default_factory=datetime.utcnow)
    
    class Settings:
        name = "student_answers"
        indexes = [
            "student_id",
            "question_id",
            "unit_id",
            [("student_id", 1), ("unit_id", 1)],  # Compound index
        ]


class StudentAbilityModel(Document):
    """Student ability tracking using IRT"""
    student_id: Indexed(str, unique=True)  # Unique index
    unit_id: int
    current_difficulty: int = Field(default=1, ge=1, le=5)
    ability_score: float = Field(default=0.0)  # IRT ability parameter
    concepts_mastered: Dict[str, Any] = Field(default_factory=dict)
    total_questions: int = Field(default=0)
    correct_answers: int = Field(default=0)
    last_updated: datetime = Field(default_factory=datetime.utcnow)
    
    class Settings:
        name = "student_ability"
        indexes = [
            "student_id",
            "unit_id",
        ]


# Database connection
db_client: Optional[AsyncIOMotorClient] = None


async def init_db():
    """Initialize MongoDB connection and Beanie ODM"""
    global db_client
    
    # Create Motor client
    # TLS parameters are now in the connection string
    db_client = AsyncIOMotorClient(settings.mongodb_url)
    
    # Get database
    database = db_client[settings.mongodb_db_name]
    
    # Initialize Beanie with document models
    await init_beanie(
        database=database,
        document_models=[
            DocumentModel,
            QuestionModel,
            StudentAnswerModel,
            StudentAbilityModel,
        ]
    )
    
    print(f"✅ MongoDB connected: {settings.mongodb_db_name}")


async def close_db():
    """Close MongoDB connection"""
    global db_client
    if db_client:
        db_client.close()
        print("✅ MongoDB connection closed")


# Helper function to get database (for compatibility)
async def get_db():
    """
    Get database instance.
    Note: With Beanie, you don't need to pass db session around.
    Models can be used directly.
    """
    if db_client is None:
        await init_db()
    return db_client[settings.mongodb_db_name]
