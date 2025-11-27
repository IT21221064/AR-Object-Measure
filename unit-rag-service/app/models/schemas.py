from datetime import datetime
from typing import List, Optional, Dict, Any
from pydantic import BaseModel, Field


# Document Schemas
class DocumentUpload(BaseModel):
    title: str
    grade_levels: List[int] = Field(..., description="List of kindergarten grade levels (1-4)")
    topic: str
    uploaded_by: str


class DocumentResponse(BaseModel):
    id: str  # MongoDB ObjectId as string
    title: str
    grade_levels: List[int]
    topic: str
    uploaded_by: str
    uploaded_at: datetime
    status: str
    questions_count: int = 0

    class Config:
        from_attributes = True


# Question Schemas
class QuestionOption(BaseModel):
    text: str
    is_correct: bool = False


class QuestionCreate(BaseModel):
    question_text: str
    question_type: str  # mcq, short_answer, true_false
    correct_answer: str
    options: Optional[List[str]] = None
    grade_level: int
    difficulty_level: int
    bloom_level: str
    concepts: List[str]
    explanation: str
    hints: List[str] = []


class QuestionResponse(BaseModel):
    id: str  # MongoDB ObjectId as string
    question_text: str
    question_type: str
    options: Optional[List[str]] = None
    grade_level: int
    difficulty_level: int
    bloom_level: Optional[str] = None
    concepts: List[str] = []
    explanation: Optional[str] = None
    hints: List[str] = []

    class Config:
        from_attributes = True


class QuestionUpdate(BaseModel):
    """Schema for updating questions"""
    question_text: Optional[str] = None
    correct_answer: Optional[str] = None
    options: Optional[List[str]] = None
    difficulty_level: Optional[int] = None
    explanation: Optional[str] = None
    hints: Optional[List[str]] = None

    class Config:
        from_attributes = True


# Question Generation Schemas
class QuestionGenerationRequest(BaseModel):
    document_id: str = Field(..., description="MongoDB document ID (get from /api/v1/upload/ endpoint)", example="69249f2aea9d88b2815084f5")
    grade_levels: List[int] = Field(default=[1, 2, 3, 4], description="Grade levels for kindergarten (1-4)", example=[1, 2, 3, 4])
    questions_per_grade: int = Field(default=10, description="Number of questions per grade level", ge=1, le=50)
    question_types: List[str] = Field(default=["mcq", "short_answer"], description="Types of questions to generate")


class QuestionGenerationResponse(BaseModel):
    job_id: str
    status: str
    estimated_time: str
    message: str


# Adaptive Learning Schemas
class AdaptiveQuestionRequest(BaseModel):
    student_id: str
    unit_id: int
    grade_level: Optional[int] = None


class AdaptiveQuestionResponse(BaseModel):
    question_id: str  # MongoDB ObjectId as string
    question_text: str
    question_type: str
    options: Optional[List[str]]
    difficulty: int
    hints: List[str]
    current_ability: float
    estimated_probability: float


class AnswerSubmission(BaseModel):
    student_id: str
    question_id: str  # MongoDB ObjectId as string
    unit_id: int
    answer: str
    time_taken: Optional[int] = None  # seconds


class AnswerFeedback(BaseModel):
    is_correct: bool
    correct_answer: str
    explanation: Optional[str] = None
    new_ability_score: float
    recommended_difficulty: int
    progress_percentage: float


# Student Progress Schemas
class StudentProgress(BaseModel):
    student_id: str
    unit_id: int
    total_questions: int
    correct_answers: int
    current_difficulty: int
    ability_score: float
    concepts_mastered: Dict[str, float]
    last_activity: datetime


class StudentAnswerRecord(BaseModel):
    id: str  # MongoDB ObjectId as string
    student_id: str
    question_id: str  # MongoDB ObjectId as string
    unit_id: int
    answer_given: str
    is_correct: bool
    time_taken: int
    difficulty_at_attempt: int
    answered_at: datetime

    class Config:
        from_attributes = True


# Analytics Schemas
class StudentAnalytics(BaseModel):
    student_id: str
    unit_id: int
    ability_score: float
    total_questions: int
    correct_answers: int
    accuracy: float
    concepts_mastered: Dict[str, Any]
    current_difficulty: int
    performance_trend: List[Any] = []
    weak_concepts: List[str] = []
    strong_concepts: List[str] = []
