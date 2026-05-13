"""Verify streaming tool calls via the official openai SDK."""
import json
from openai import OpenAI

client = OpenAI(base_url="http://127.0.0.1:11434/v1", api_key="x")

TOOLS = [{"type":"function","function":{
    "name":"add","description":"Returns a+b.",
    "parameters":{"type":"object",
                  "properties":{"a":{"type":"integer"},"b":{"type":"integer"}},
                  "required":["a","b"]}
}}]

print("Streaming tool call via openai SDK ...")
stream = client.chat.completions.create(
    model="apple-fm",
    messages=[{"role":"user","content":"What is 17 plus 25? Use the add tool."}],
    tools=TOOLS,
    max_tokens=120, temperature=0,
    stream=True,
)

calls = []
for chunk in stream:
    delta = chunk.choices[0].delta
    if delta.tool_calls:
        for tc in delta.tool_calls:
            while len(calls) <= tc.index:
                calls.append({"id": None, "name": None, "arguments": ""})
            if tc.id:
                calls[tc.index]["id"] = tc.id
            if tc.function:
                if tc.function.name:
                    calls[tc.index]["name"] = tc.function.name
                if tc.function.arguments:
                    calls[tc.index]["arguments"] += tc.function.arguments

print(f"Accumulated tool calls: {calls}")
