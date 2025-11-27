import json
from typing import List, Dict, Any
from app.utils.llm_client import llm_client
from app.services.embeddings_service import embeddings_service


class QuestionGenerator:
    """Generate questions from document content using LLM"""
    
    # Grade-specific prompts
    GRADE_PROMPTS = {
        1: {
            "system": "You are creating questions for Grade 1 students (ages 6-7). Use simple words from the 200 most common English words. Keep questions 5-10 words long. Focus on visual recognition, counting, and basic identification. Use emojis to make it fun!",
            "bloom_levels": ["remember", "understand"],
            "question_types": ["mcq", "true_false"],
            "difficulty_range": [1, 2]
        },
        2: {
            "system": "You are creating questions for Grade 2 students (ages 7-8). Use simple vocabulary and short sentences. Focus on basic comprehension, simple calculations, and comparison. Make it engaging with emojis!",
            "bloom_levels": ["remember", "understand"],
            "question_types": ["mcq", "short_answer"],
            "difficulty_range": [2, 3]
        },
        3: {
            "system": "You are creating questions for Grade 3 students (ages 8-9). Use grade-appropriate vocabulary. Focus on application, simple problem-solving, and multi-step thinking. Include helpful hints!",
            "bloom_levels": ["understand", "apply"],
            "question_types": ["mcq", "short_answer"],
            "difficulty_range": [3, 4]
        },
        4: {
            "system": "You are creating questions for Grade 4 students (ages 9-10). Focus on analysis, reasoning, word problems, and applying concepts to new situations. Encourage critical thinking!",
            "bloom_levels": ["apply", "analyze"],
            "question_types": ["mcq", "short_answer"],
            "difficulty_range": [4, 5]
        }
    }
    
    async def generate_questions_from_context(
        self,
        context: str,
        grade_level: int,
        topic: str,
        num_questions: int = 5
    ) -> List[Dict[str, Any]]:
        """Generate questions from given context"""
        
        if grade_level not in self.GRADE_PROMPTS:
            raise ValueError(f"Invalid grade level: {grade_level}")
        
        grade_config = self.GRADE_PROMPTS[grade_level]
        
        prompt = f"""
Based on this educational content, generate questions ONLY about {topic.upper()} measurement:

{context}

IMPORTANT RULES:
- Generate ONLY questions about {topic.upper()} (e.g., {topic} units, {topic} conversions, {topic} measurements)
- DO NOT include questions about other measurement topics
- Focus exclusively on {topic}-related concepts

Generate {num_questions} questions for Grade {grade_level} students following these rules:

1. Topic Focus: ONLY {topic.upper()} - ignore all other topics in the content
2. Question Types: Use {', '.join(grade_config['question_types'])}
3. Difficulty: Range from {grade_config['difficulty_range'][0]} to {grade_config['difficulty_range'][1]} (1=easiest, 5=hardest)
4. Bloom's Taxonomy: Focus on {', '.join(grade_config['bloom_levels'])}
5. For MCQ questions: Provide exactly 4 options, with one correct answer
6. Include helpful hints that guide without giving away the answer
7. Provide clear explanations for the correct answer
8. Tag relevant concepts covered (related to {topic} only)

Return ONLY valid JSON in this exact format:
{{
  "questions": [
    {{
      "question_text": "Your question here",
      "question_type": "mcq or short_answer or true_false",
      "correct_answer": "The correct answer",
      "options": ["Option 1", "Option 2", "Option 3", "Option 4"],
      "difficulty_level": 1-5,
      "bloom_level": "remember/understand/apply/analyze",
      "concepts": ["concept1", "concept2"],
      "explanation": "Why this is the correct answer",
      "hints": ["Helpful hint 1", "Helpful hint 2"]
    }}
  ]
}}

Make questions engaging, age-appropriate, and educational!
"""
        
        try:
            response = await llm_client.generate_completion(
                prompt=prompt,
                system_message=grade_config['system'],
                temperature=0.8,
                max_tokens=2000
            )
            
            # Parse JSON response
            # Remove markdown code blocks if present
            response = response.strip()
            if response.startswith('```json'):
                response = response[7:]
            if response.startswith('```'):
                response = response[3:]
            if response.endswith('```'):
                response = response[:-3]
            
            questions_data = json.loads(response.strip())
            
            # Add grade level to each question
            for q in questions_data.get('questions', []):
                q['grade_level'] = grade_level
            
            return questions_data.get('questions', [])
        
        except json.JSONDecodeError as e:
            raise Exception(f"Failed to parse LLM response as JSON: {str(e)}")
        except Exception as e:
            raise Exception(f"Error generating questions: {str(e)}")
    
    async def generate_questions_for_document(
        self,
        document_id: str,
        document_content: str,
        grade_levels: List[int],
        topic: str = "measurement",
        questions_per_grade: int = 10,
        question_types: List[str] = None
    ) -> List[Dict[str, Any]]:
        """Generate questions for a document across multiple grades"""
        
        if not document_content or len(document_content) < 50:
            raise Exception("Document content is too short or empty")
        
        # Use document content directly instead of vector search
        # Truncate if too long (keep first 3000 chars to stay within token limits)
        context = document_content[:3000] if len(document_content) > 3000 else document_content
        
        # Generate questions for each grade level
        all_questions = []
        
        for grade in grade_levels:
            try:
                print(f"🎯 Generating {questions_per_grade} questions for grade {grade} (Topic: {topic})...")
                questions = await self.generate_questions_from_context(
                    context=context,
                    grade_level=grade,
                    topic=topic,
                    num_questions=questions_per_grade
                )
                all_questions.extend(questions)
                print(f"✅ Generated {len(questions)} questions for grade {grade}")
            except Exception as e:
                print(f"❌ Error generating questions for grade {grade}: {str(e)}")
                continue
        
        return all_questions
    
    async def regenerate_question_with_adjustments(
        self,
        original_question: Dict[str, Any],
        adjustments: str
    ) -> Dict[str, Any]:
        """Regenerate a question with specific adjustments"""
        
        prompt = f"""
Original question:
{json.dumps(original_question, indent=2)}

Adjustment request: {adjustments}

Generate an improved version maintaining the same format but applying the requested changes.

Return ONLY valid JSON:
{{
  "question_text": "...",
  "question_type": "...",
  "correct_answer": "...",
  "options": [...],
  "difficulty_level": ...,
  "bloom_level": "...",
  "concepts": [...],
  "explanation": "...",
  "hints": [...]
}}
"""
        
        try:
            response = await llm_client.generate_completion(
                prompt=prompt,
                system_message="You are an expert educational content creator.",
                temperature=0.7
            )
            
            # Clean and parse response
            response = response.strip()
            if response.startswith('```json'):
                response = response[7:]
            if response.startswith('```'):
                response = response[3:]
            if response.endswith('```'):
                response = response[:-3]
            
            improved_question = json.loads(response.strip())
            return improved_question
        
        except Exception as e:
            raise Exception(f"Error regenerating question: {str(e)}")


# Singleton instance
question_generator = QuestionGenerator()
