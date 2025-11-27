import numpy as np
from typing import List, Dict, Any, Optional
from app.models.database import StudentAbilityModel, StudentAnswerModel, QuestionModel
from app.config import settings


class AdaptiveEngine:
    """
    Adaptive question selection using Item Response Theory (IRT)
    Implements 1-Parameter Logistic Model (Rasch Model)
    """
    
    def __init__(self):
        self.learning_rate = settings.learning_rate
        self.target_success_rate = settings.target_success_rate
        self.min_difficulty = settings.min_difficulty
        self.max_difficulty = settings.max_difficulty
    
    def probability_correct(self, ability: float, difficulty: float) -> float:
        """
        Calculate probability of correct answer using IRT
        P(correct) = 1 / (1 + exp(-(ability - difficulty)))
        """
        return 1.0 / (1.0 + np.exp(-(ability - difficulty)))
    
    def update_ability(
        self,
        current_ability: float,
        is_correct: bool,
        question_difficulty: float
    ) -> float:
        """
        Update student ability based on answer correctness
        Uses Maximum Likelihood Estimation
        """
        prob = self.probability_correct(current_ability, question_difficulty)
        
        if is_correct:
            # Increase ability based on how surprising the success was
            delta = self.learning_rate * (1 - prob)
        else:
            # Decrease ability based on how surprising the failure was
            delta = -self.learning_rate * prob
        
        new_ability = current_ability + delta
        
        # Clamp to reasonable range
        return max(-3.0, min(3.0, new_ability))
    
    def select_optimal_difficulty(self, ability: float) -> int:
        """
        Select optimal question difficulty for target success rate
        
        For 70% success rate: difficulty = ability - ln(1/0.7 - 1) ≈ ability - 0.85
        """
        # Calculate continuous difficulty
        optimal_difficulty = ability - np.log((1.0 / self.target_success_rate) - 1)
        
        # Convert to discrete difficulty level (1-5)
        difficulty_level = int(np.round(optimal_difficulty)) + 3  # Center at 3
        
        # Clamp to valid range
        return max(self.min_difficulty, min(self.max_difficulty, difficulty_level))
    
    async def get_student_state(
        self,
        student_id: str,
        unit_id: str
    ) -> StudentAbilityModel:
        """Get or create student ability state"""
        
        student_ability = await StudentAbilityModel.find_one(
            StudentAbilityModel.student_id == student_id,
            StudentAbilityModel.unit_id == unit_id
        )
        
        if not student_ability:
            # Create new student record
            student_ability = StudentAbilityModel(
                student_id=student_id,
                unit_id=unit_id,
                ability_score=settings.initial_ability_score,
                current_difficulty=3,  # Start at medium
                concepts_mastered={}
            )
            await student_ability.insert()
        
        return student_ability
    
    async def get_next_question(
        self,
        student_id: str,
        unit_id: str,
        grade_level: Optional[int] = None
    ) -> Optional[QuestionModel]:
        """
        Select next question using adaptive algorithm
        
        Algorithm:
        1. Get student's current ability
        2. Calculate optimal difficulty
        3. Identify weak concepts
        4. Find unanswered question matching criteria
        """
        
        # Get student state
        student_ability = await self.get_student_state(student_id, unit_id)
        
        # Calculate optimal difficulty
        target_difficulty = self.select_optimal_difficulty(student_ability.ability_score)
        
        # Get answered question IDs
        answered = await StudentAnswerModel.find(
            StudentAnswerModel.student_id == student_id,
            StudentAnswerModel.unit_id == unit_id
        ).to_list()
        answered_ids = [str(ans.question_id) for ans in answered]
        
        # Identify weak concepts (mastery < 0.5)
        weak_concepts = [
            concept for concept, mastery 
            in (student_ability.concepts_mastered or {}).items() 
            if mastery < 0.5
        ]
        
        # Build base query with unit_id filter
        base_query = {"unit_id": unit_id}
        if answered_ids:
            base_query["_id"] = {"$nin": answered_ids}
        
        # Priority 1: Questions on weak concepts at target difficulty
        if weak_concepts:
            question = await QuestionModel.find_one(
                base_query,
                QuestionModel.difficulty_level == target_difficulty,
                {"concepts": {"$in": weak_concepts}}
            )
            
            if question:
                return question
        
        # Priority 2: Any question at target difficulty for this unit
        question = await QuestionModel.find_one(
            base_query,
            QuestionModel.difficulty_level == target_difficulty
        )
        
        if question:
            return question
        
        # Priority 3: Question at adjacent difficulty for this unit
        for diff_offset in [1, -1, 2, -2]:
            adj_difficulty = target_difficulty + diff_offset
            if self.min_difficulty <= adj_difficulty <= self.max_difficulty:
                question = await QuestionModel.find_one(
                    base_query,
                    {"_id": {"$nin": answered_ids}} if answered_ids else {},
                    QuestionModel.difficulty_level == adj_difficulty
                )
                
                if question:
                    return question
        
        # Fallback: Any unanswered question
        return await QuestionModel.find_one(
            {"_id": {"$nin": answered_ids}} if answered_ids else {}
        )
    
    async def process_answer(
        self,
        student_id: str,
        question: QuestionModel,
        is_correct: bool,
        time_taken: int
    ) -> Dict[str, Any]:
        """
        Process student answer and update ability
        
        Returns feedback and updated state
        """
        
        # Get student state
        student_ability = await self.get_student_state(student_id, str(question.id))
        
        # Update ability score
        new_ability = self.update_ability(
            student_ability.ability_score,
            is_correct,
            question.difficulty_level
        )
        
        # Update concept mastery
        concepts_mastered = student_ability.concepts_mastered or {}
        for concept in (question.concepts or []):
            current_mastery = concepts_mastered.get(concept, 0.5)
            
            # Update mastery (exponential moving average)
            if is_correct:
                new_mastery = current_mastery + 0.1 * (1 - current_mastery)
            else:
                new_mastery = current_mastery - 0.1 * current_mastery
            
            concepts_mastered[concept] = round(new_mastery, 3)
        
        # Update student record
        student_ability.ability_score = new_ability
        student_ability.current_difficulty = self.select_optimal_difficulty(new_ability)
        student_ability.concepts_mastered = concepts_mastered
        student_ability.total_questions += 1
        if is_correct:
            student_ability.correct_answers += 1
        
        await student_ability.save()
        
        # Record answer
        answer_record = StudentAnswerModel(
            student_id=student_id,
            question_id=str(question.id),
            unit_id=str(question.id),  # Assuming question.id relates to unit
            answer_given="",  # Will be filled by caller
            is_correct=is_correct,
            time_taken=time_taken,
            difficulty_at_attempt=question.difficulty_level
        )
        
        await answer_record.insert()
        
        # Calculate mastery level (overall accuracy)
        mastery_level = (
            student_ability.correct_answers / student_ability.total_questions
            if student_ability.total_questions > 0 else 0.0
        )
        
        # Identify concepts to review
        concepts_to_review = [
            concept for concept, mastery 
            in concepts_mastered.items() 
            if mastery < 0.6
        ]
        
        return {
            "ability_score": new_ability,
            "next_difficulty": student_ability.current_difficulty,
            "mastery_level": mastery_level,
            "concepts_to_review": concepts_to_review,
            "probability_next": self.probability_correct(
                new_ability,
                student_ability.current_difficulty
            )
        }
    
    async def calculate_analytics(
        self,
        student_id: str,
        unit_id: str
    ) -> Dict[str, Any]:
        """Calculate student analytics and learning metrics"""
        
        student_ability = await StudentAbilityModel.find_one(
            StudentAbilityModel.student_id == student_id,
            StudentAbilityModel.unit_id == unit_id
        )
        
        if not student_ability:
            return {}
        
        # Get all answers
        answers = await StudentAnswerModel.find(
            StudentAnswerModel.student_id == student_id,
            StudentAnswerModel.unit_id == unit_id
        ).sort("answered_at").to_list()
        
        if not answers:
            return {}
        
        # Calculate metrics
        total_time = sum(a.time_taken for a in answers)
        accuracy = student_ability.correct_answers / len(answers)
        avg_difficulty = np.mean([a.difficulty_at_attempt for a in answers])
        
        # Learning velocity (improvement rate)
        if len(answers) >= 5:
            recent_accuracy = sum(
                1 for a in answers[-5:] if a.is_correct
            ) / 5
            early_accuracy = sum(
                1 for a in answers[:5] if a.is_correct
            ) / 5
            learning_velocity = recent_accuracy - early_accuracy
        else:
            learning_velocity = 0.0
        
        # Strong and weak concepts
        concepts = student_ability.concepts_mastered or {}
        strong_concepts = [c for c, m in concepts.items() if m >= 0.7]
        weak_concepts = [c for c, m in concepts.items() if m < 0.5]
        
        return {
            "total_time_spent": total_time,
            "questions_attempted": len(answers),
            "accuracy_rate": accuracy,
            "average_difficulty": avg_difficulty,
            "strong_concepts": strong_concepts,
            "weak_concepts": weak_concepts,
            "learning_velocity": learning_velocity,
            "recommended_difficulty": student_ability.current_difficulty,
            "ability_score": student_ability.ability_score
        }


# Singleton instance
adaptive_engine = AdaptiveEngine()
