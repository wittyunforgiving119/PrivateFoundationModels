"""Verify OpenAI tool calling via the official SDK against pfm-serve."""
import json
from openai import OpenAI

client = OpenAI(base_url="http://127.0.0.1:11434/v1", api_key="not-required")

def add(a, b):
    return a + b

TOOLS = [{
    "type": "function",
    "function": {
        "name": "add",
        "description": "Returns a+b.",
        "parameters": {
            "type": "object",
            "properties": {"a": {"type": "integer"}, "b": {"type": "integer"}},
            "required": ["a", "b"],
        },
    },
}]

messages = [{"role": "user", "content": "What is 17 plus 25? Use the add tool."}]
resp = client.chat.completions.create(
    model="apple-fm", messages=messages, tools=TOOLS,
    max_tokens=120, temperature=0,
)
print("Round 1: assistant turn —", resp.choices[0].finish_reason)
msg = resp.choices[0].message
if msg.tool_calls:
    call = msg.tool_calls[0]
    args = json.loads(call.function.arguments)
    result = str(add(**args))
    print(f"  Tool call: {call.function.name}({args})  →  {result}")
    messages.append({
        "role": "assistant", "content": None,
        "tool_calls": [{
            "id": call.id, "type": "function",
            "function": {"name": call.function.name, "arguments": call.function.arguments},
        }],
    })
    messages.append({"role": "tool", "tool_call_id": call.id, "content": result})

    resp2 = client.chat.completions.create(
        model="apple-fm", messages=messages, tools=TOOLS,
        max_tokens=60, temperature=0,
    )
    print("Round 2: final answer —", resp2.choices[0].message.content)
else:
    print("  Model returned content directly:", msg.content)
