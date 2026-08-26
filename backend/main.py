import os
from dotenv import load_dotenv
from fastapi import FastAPI, UploadFile, File, Form
from pydantic import BaseModel
from langgraph.graph import StateGraph, END
from langchain_groq import ChatGroq
from groq import Groq
from typing import TypedDict, List
import tempfile

# Load environment variables
load_dotenv()

# 1. Define the State
class GraphState(TypedDict):
    raw_text: str
    participant_count: int
    roles: List[str]
    formatted_notes: str

# 2. Initialize the AI Models
llm = ChatGroq(model="openai/gpt-oss-20b", temperature=0)
groq_client = Groq(api_key=os.environ.get("GROQ_API_KEY"))

# 3. Transcription Node (The Ears)
def transcribe_audio_node(state: GraphState):
    # This will be called separately since we need the audio file
    return state

# 4. Formatting Node (The Brain)
def format_notes_node(state: GraphState):
    raw_text = state["raw_text"]
    participant_count = state["participant_count"]
    roles = state["roles"]
    
    roles_str = ", ".join(roles)
    
    prompt = f"""
    You are an expert meeting assistant. You are given a raw, unformatted transcript and metadata about the meeting.
    
    MEETING METADATA:
    - Total number of participants: {participant_count}
    - Expected roles in the meeting: {roles_str}
    
    YOUR TASK:
    1. Analyze the conversational flow (who asks questions, who gives approvals, who talks about specific topics).
    2. Infer who is speaking and assign them one of the roles from the metadata (e.g., "Manager", "Team Member 1", "Client").
    3. Format the output into clean, structured notes with the following sections:
    
    - **Participants**: List the inferred speakers and their assigned roles.
    - **Summary**: A 2-sentence overview of the conversation.
    - **Key Discussion**: A brief, bulleted breakdown of who said what, using their inferred roles (e.g., "- Manager asked about the timeline, Developer replied...").
    - **Decisions**: Bullet points of what was agreed upon.
    - **Action Items**: Bullet points with clear owners (using their roles) and tasks.

    RAW TRANSCRIPT:
    {raw_text}
    """
    
    response = llm.invoke(prompt)
    return {"formatted_notes": response.content}

# 5. Build the Graph
workflow = StateGraph(GraphState)
workflow.add_node("format_notes", format_notes_node)
workflow.set_entry_point("format_notes")
workflow.add_edge("format_notes", END)

graph = workflow.compile() 

# 6. FastAPI Setup
app = FastAPI()

# Helper function to transcribe audio
def transcribe_audio(audio_file_path: str) -> str:
    with open(audio_file_path, "rb") as file:
        transcription = groq_client.audio.transcriptions.create(
            file=(audio_file_path, file.read()),
            model="whisper-large-v3-turbo",
            response_format="text",
            language="en",
            temperature=0.0
        )
    return transcription

# Endpoint 1: Process audio file with metadata
@app.post("/process-audio-meeting")
async def process_audio_meeting(
    audio: UploadFile = File(...),
    participant_count: int = Form(...),
    roles: str = Form(...)  # Comma-separated roles like "Manager,Developer,Client"
):
    # Save the uploaded audio to a temporary file
    with tempfile.NamedTemporaryFile(delete=False, suffix=f".{audio.filename.split('.')[-1]}") as temp_file:
        temp_file.write(await audio.read())
        temp_file_path = temp_file.name
    
    try:
        # Step 1: Transcribe the audio
        raw_text = transcribe_audio(temp_file_path)
        
        # Step 2: Parse the roles
        roles_list = [role.strip() for role in roles.split(",")]
        
        # Step 3: Run the formatting graph
        result = graph.invoke({
            "raw_text": raw_text,
            "participant_count": participant_count,
            "roles": roles_list
        })
        
        return {
            "transcript": raw_text,
            "notes": result["formatted_notes"]
        }
    finally:
        # Clean up the temporary file
        os.unlink(temp_file_path)

# Endpoint 2: Process text with metadata (for testing)
class MeetingInput(BaseModel):
    text: str
    participant_count: int
    roles: List[str]

@app.post("/process-meeting")
def process_meeting(data: MeetingInput):
    result = graph.invoke({
        "raw_text": data.text,
        "participant_count": data.participant_count,
        "roles": data.roles
    })
    return {"notes": result["formatted_notes"]}

# It reuses the transcribe_audio() helper you already have -
# no LLM/LangGraph call here, just Whisper. Formatting still
# only happens once, at the end, via /process-meeting.
 
@app.post("/transcribe-chunk")
async def transcribe_chunk(
    audio: UploadFile = File(...),
    chunk_index: int = Form(...),
):
    with tempfile.NamedTemporaryFile(
        delete=False, suffix=f".{audio.filename.split('.')[-1]}"
    ) as temp_file:
        temp_file.write(await audio.read())
        temp_file_path = temp_file.name
 
    try:
        text = transcribe_audio(temp_file_path)
        return {"chunk_index": chunk_index, "transcript": text}
    finally:
        os.unlink(temp_file_path)