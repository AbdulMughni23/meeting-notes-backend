import os
from dotenv import load_dotenv
from groq import Groq

load_dotenv()
client = Groq(api_key=os.environ.get("GROQ_API_KEY"))

try:
    models = client.models.list()
    print("✅ SUCCESS! Here are the models you can use:")
    for model in models.data:
        print(f"- {model.id}")
except Exception as e:
    print(f"❌ ERROR: {e}")