from fastapi import APIRouter, HTTPException
from typing import Optional
from app.models.database import QuestionModel, StudentAnswerModel, StudentAbilityModel
from app.models.schemas import (
    AdaptiveQuestionRequest,
    QuestionResponse,
    AnswerSubmission,
    AnswerFeedback,
    StudentAnalytics
)
from app.services.adaptive_engine import adaptive_engine

router = APIRouter(prefix="/api/v1/adaptive", tags=["adaptive"])


@router.get("/next-question", response_model=QuestionResponse)
async def get_next_question(
    student_id: str,
    unit_id: str,
    grade_level: Optional[int] = None
):
    """
    Get the next adaptive question for a student
    
    - Uses IRT to select optimal difficulty
    - Returns question tailored to student's current ability
    """
    # Get next question using adaptive engine (creates student if needed)
    question = await adaptive_engine.get_next_question(
        student_id=student_id,
        unit_id=unit_id,
        grade_level=grade_level
    )
    
    if not question:
        raise HTTPException(
            status_code=404,
            detail="No suitable questions found for this student"
        )
    
    return QuestionResponse(
        id=str(question.id),
        question_text=question.question_text,
        question_type=question.question_type,
        options=question.options or [],
        grade_level=question.grade_level,
        difficulty_level=question.difficulty_level,
        bloom_level=question.bloom_level or "",
        concepts=question.concepts or [],
        explanation=None,  # Don't send answer/explanation yet
        hints=question.hints or []
    )


@router.post("/submit-answer", response_model=AnswerFeedback)
async def submit_answer(submission: AnswerSubmission):
    """
    Submit an answer and get feedback
    
    - Evaluates answer correctness
    - Updates student ability using IRT
    - Returns feedback and explanation
    """
    # Get question
    question = await QuestionModel.get(submission.question_id)
    
    if not question:
        raise HTTPException(status_code=404, detail="Question not found")
    
    # Evaluate answer correctness
    is_correct = (submission.answer.strip().lower() == question.correct_answer.strip().lower())
    
    # Process answer through adaptive engine (updates ability and records answer)
    feedback_data = await adaptive_engine.process_answer(
        student_id=submission.student_id,
        question=question,
        is_correct=is_correct,
        time_taken=submission.time_taken
    )
    
    return AnswerFeedback(
        is_correct=is_correct,
        correct_answer=question.correct_answer,
        explanation=question.explanation or "",
        new_ability_score=feedback_data["ability_score"],
        recommended_difficulty=feedback_data["next_difficulty"],
        progress_percentage=feedback_data["mastery_level"] * 100
    )


@router.get("/analytics/{student_id}", response_model=StudentAnalytics)
async def get_student_analytics(
    student_id: str,
    unit_id: Optional[str] = None
):
    """
    Get student learning analytics
    
    - Overall performance
    - Concept mastery
    - Progress over time
    """
    query = {"student_id": student_id}
    if unit_id:
        query["unit_id"] = unit_id
    
    student_ability = await StudentAbilityModel.find_one(query)
    
    if not student_ability:
        raise HTTPException(status_code=404, detail="Student record not found")
    
    # Calculate analytics
    analytics = await adaptive_engine.calculate_analytics(student_id, unit_id or student_ability.unit_id)
    
    return StudentAnalytics(
        student_id=student_id,
        unit_id=student_ability.unit_id,
        ability_score=student_ability.ability_score,
        total_questions=student_ability.total_questions,
        correct_answers=student_ability.correct_answers,
        accuracy=(student_ability.correct_answers / student_ability.total_questions * 100) if student_ability.total_questions > 0 else 0,
        concepts_mastered=student_ability.concepts_mastered or {},
        current_difficulty=student_ability.current_difficulty,
        performance_trend=analytics.get("performance_trend", []),
        weak_concepts=analytics.get("weak_concepts", []),
        strong_concepts=analytics.get("strong_concepts", [])
    )
