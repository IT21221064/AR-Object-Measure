from openai import OpenAI
from typing import List
from app.config import settings

# Initialize OpenAI client
client = OpenAI(api_key=settings.openai_api_key)


class LLMClient:
    """Client for interacting with OpenAI API"""
    
    def __init__(self):
        self.client = client
        self.model = settings.openai_model
    
    async def generate_completion(
        self,
        prompt: str,
        system_message: str = "You are a helpful assistant.",
        temperature: float = 0.7,
        max_tokens: int = 2000,
    ) -> str:
        """Generate completion from OpenAI"""
        try:
            response = self.client.chat.completions.create(
                model=self.model,
                messages=[
                    {"role": "system", "content": system_message},
                    {"role": "user", "content": prompt}
                ],
                temperature=temperature,
                max_tokens=max_tokens,
            )
            return response.choices[0].message.content
        except Exception as e:
            raise Exception(f"OpenAI API error: {str(e)}")
    
    async def generate_embeddings(self, texts: List[str]) -> List[List[float]]:
        """Generate embeddings for texts"""
        try:
            response = self.client.embeddings.create(
                model=settings.embedding_model,
                input=texts
            )
            return [item.embedding for item in response.data]
        except Exception as e:
            raise Exception(f"Embedding generation error: {str(e)}")


# Singleton instance
llm_client = LLMClient()
