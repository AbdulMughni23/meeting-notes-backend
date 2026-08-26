import os
from dotenv import load_dotenv
from groq import Groq

# Load the .env file
load_dotenv()

# Initialize the client
client = Groq(api_key=os.environ.get("GROQ_API_KEY"))

# The path to your audio file
audio_file_path = "E:/deep seek harness/projects_deepseek_harness/backend/data/example.m4a" 


print(f"🎙️ Transcribing {audio_file_path}... please wait.")

# Send the audio to Groq's Whisper model
with open(audio_file_path, "rb") as file:
    transcription = client.audio.transcriptions.create(
        file=(audio_file_path, file.read()),
        model="whisper-large-v3-turbo", # The fastest, free Whisper model
        response_format="text",
        language="en",
        temperature=0.0
    )

print("✅ SUCCESS! Here is what the AI heard:")
print("-" * 40)
print(transcription)
print("-" * 40)