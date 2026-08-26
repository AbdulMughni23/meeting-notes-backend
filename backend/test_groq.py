import os
from dotenv import load_dotenv
from groq import Groq

# Load the .env file
load_dotenv()

# Initialize the client
client = Groq(api_key=os.environ.get("GROQ_API_KEY"))

# Test the model we KNOW you have access to
completion = client.chat.completions.create(
    model="openai/gpt-oss-20b",
    messages=[
        {"role": "user", "content": "Reply with exactly: 'Groq is working with the new model!'"}
    ]
)

print(completion.choices[0].message.content)