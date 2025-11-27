from fastapi import APIRouter, UploadFile, File, Form, HTTPException
from typing import List
import uuid
from app.models.database import DocumentModel
from app.models.schemas import DocumentResponse
from app.utils.document_processor import document_processor
from app.services.embeddings_service import embeddings_service
from app.config import settings

router = APIRouter(prefix="/api/v1/upload", tags=["upload"])


@router.post("/", response_model=DocumentResponse)
async def upload_document(
    file: UploadFile = File(..., description="Document file (PDF, DOCX, or TXT)"),
    grade_levels: str = Form("1", description="Comma-separated grade levels (1-4 for kindergarten)", example="1,2,3,4"),
    topic: str = Form("Length", description="Topic name (e.g., Length, Area, Weight)", example="Length"),
    title: str = Form(None, description="Document title (optional, uses filename if not provided)"),
    uploaded_by: str = Form(None, description="Uploader ID (optional)")
):
    """
    Upload and process a document
    
    - Accepts PDF, DOCX, or TXT files
    - Extracts text content
    - Creates embeddings and stores in vector database
    - Returns document metadata
    
    Required fields:
    - file: The document file (PDF, DOCX, TXT)
    - grade_levels: Comma-separated grades (e.g., "5,6,7")
    - topic: Topic name (e.g., "Length", "Area", "Capacity", "Weight")
    
    Optional fields:
    - title: Document title (defaults to filename)
    - uploaded_by: Teacher/uploader ID
    """
    
    # Use filename as title if not provided
    if not title:
        title = file.filename
    
    # Validate file extension
    file_ext = file.filename.split('.')[-1].lower()
    if file_ext not in settings.allowed_extensions:
        raise HTTPException(
            status_code=400,
            detail=f"File type not allowed. Allowed: {', '.join(settings.allowed_extensions)}"
        )
    
    # Validate file size
    file_content = await file.read()
    if len(file_content) > settings.max_upload_size:
        raise HTTPException(
            status_code=400,
            detail=f"File too large. Max size: {settings.max_upload_size / 1024 / 1024}MB"
        )
    
    try:
        # Extract text from document
        text_content = document_processor.extract_text(file_content, file.filename)
        
        # Clean text
        text_content = document_processor.clean_text(text_content)
        
        if not text_content or len(text_content) < 100:
            raise HTTPException(
                status_code=400,
                detail="Document content is too short or could not be extracted"
            )
        
        # Parse grade levels
        # Check for common mistakes from Swagger UI
        if grade_levels.lower() in ['string', 'str', 'example']:
            raise HTTPException(
                status_code=400,
                detail="Please replace the example 'string' with actual grade levels (e.g., '5' or '5,6,7')"
            )
        
        try:
            grade_list = [int(g.strip()) for g in grade_levels.split(',') if g.strip()]
            if not grade_list:
                raise ValueError("No grades provided")
            # Validate grade ranges (kindergarten grades 1-4)
            if any(g < 1 or g > 4 for g in grade_list):
                raise ValueError("Grade levels must be between 1 and 4 for kindergarten students")
        except ValueError as e:
            raise HTTPException(
                status_code=400,
                detail=f"Invalid grade_levels. Use comma-separated numbers (e.g., '1,2,3,4'). Error: {str(e)}"
            )
        
        # Create document record in MongoDB
        document = DocumentModel(
            title=title,
            content=text_content,
            grade_levels=grade_list,
            topic=topic,
            uploaded_by=uploaded_by or "anonymous",
            status="processing"
        )
        await document.insert()
        
        # Generate unique document ID for vector store
        vector_doc_id = f"doc_{str(document.id)}_{uuid.uuid4().hex[:8]}"
        
        # Chunk the text
        chunks = document_processor.chunk_text(
            text_content,
            chunk_size=settings.chunk_size,
            overlap=settings.chunk_overlap
        )
        
        # Add to vector database
        metadata = {
            "document_id": str(document.id),
            "title": title,
            "topic": topic,
            "grade_levels": grade_list
        }
        
        await embeddings_service.add_document_chunks(
            document_id=vector_doc_id,
            chunks=chunks,
            metadata=metadata
        )
        
        # Update document status
        document.vector_db_id = vector_doc_id
        document.status = "completed"
        await document.save()
        
        # Auto-generate questions in background after upload
        from app.services.question_generator import question_generator
        try:
            print(f"🚀 Auto-generating questions for document {document.id}")
            questions = await question_generator.generate_questions_for_document(
                document_id=str(document.id),
                document_content=text_content,
                grade_levels=grade_list,
                topic=topic,  # Pass the topic to focus question generation
                questions_per_grade=5  # Generate 5 questions per grade automatically
            )
            
            # Save generated questions
            from app.models.database import QuestionModel
            question_count = 0
            for q_data in questions:
                # Generate unit_id based on document topic and grade
                unit_id = f"unit_{topic.lower()}_{q_data['grade_level']}" if topic else None
                
                question = QuestionModel(
                    document_id=str(document.id),
                    unit_id=unit_id,
                    topic=topic,
                    question_text=q_data["question_text"],
                    question_type=q_data["question_type"],
                    correct_answer=q_data["correct_answer"],
                    options=q_data.get("options"),
                    grade_level=q_data["grade_level"],
                    difficulty_level=q_data["difficulty_level"],
                    bloom_level=q_data.get("bloom_level"),
                    concepts=q_data.get("concepts", []),
                    explanation=q_data.get("explanation"),
                    hints=q_data.get("hints", [])
                )
                await question.insert()
                question_count += 1
                print(f"💾 Auto-saved question {question_count}: unit_id={unit_id}, topic={topic}, grade={q_data['grade_level']}")
            
            # Update document question count
            document.questions_count = question_count
            await document.save()
            print(f"✅ Auto-generated {question_count} questions for document {document.id}")
        except Exception as e:
            print(f"⚠️ Auto-generation failed (document still uploaded): {str(e)}")
        
        return DocumentResponse(
            id=str(document.id),
            title=document.title,
            grade_levels=document.grade_levels,
            topic=document.topic,
            uploaded_by=document.uploaded_by,
            uploaded_at=document.uploaded_at,
            status=document.status,
            questions_count=document.questions_count
        )
        
    except Exception as e:
        # Log the full error for debugging
        import traceback
        print(f"❌ Error uploading document: {str(e)}")
        print(traceback.format_exc())
        
        # If document was created, update status to failed
        if 'document' in locals():
            document.status = "failed"
            await document.save()
        
        raise HTTPException(
            status_code=500,
            detail=f"Error processing document: {str(e)}"
        )


@router.get("/{document_id}", response_model=DocumentResponse)
async def get_document(document_id: str):
    """Get document by ID"""
    document = await DocumentModel.get(document_id)
    
    if not document:
        raise HTTPException(status_code=404, detail="Document not found")
    
    return DocumentResponse(
        id=str(document.id),
        title=document.title,
        grade_levels=document.grade_levels,
        topic=document.topic,
        uploaded_by=document.uploaded_by,
        uploaded_at=document.uploaded_at,
        status=document.status,
        questions_count=document.questions_count
    )


@router.get("/", response_model=List[DocumentResponse])
async def list_documents(
    topic: str = None,
    grade_level: int = None,
    status: str = None,
    skip: int = 0,
    limit: int = 20
):
    """List all documents with optional filters"""
    query = {}
    
    if topic:
        query["topic"] = topic
    if status:
        query["status"] = status
    if grade_level:
        query["grade_levels"] = grade_level
    
    documents = await DocumentModel.find(query).skip(skip).limit(limit).to_list()
    
    return [
        DocumentResponse(
            id=str(doc.id),
            title=doc.title,
            grade_levels=doc.grade_levels,
            topic=doc.topic,
            uploaded_by=doc.uploaded_by,
            uploaded_at=doc.uploaded_at,
            status=doc.status,
            questions_count=doc.questions_count
        )
        for doc in documents
    ]


@router.delete("/{document_id}")
async def delete_document(document_id: str):
    """Delete a document and its vector embeddings"""
    document = await DocumentModel.get(document_id)
    
    if not document:
        raise HTTPException(status_code=404, detail="Document not found")
    
    # Delete from vector database
    if document.vector_db_id:
        try:
            await embeddings_service.delete_document(document.vector_db_id)
        except Exception as e:
            print(f"Warning: Could not delete from vector DB: {e}")
    
    # Delete from MongoDB
    await document.delete()
    
    return {"message": "Document deleted successfully"}
