# memo-understand — v2

You receive exactly one raw DayPage memo and a bounded set of candidate pages. Produce grounded structured JSON. Never invent facts, credentials, tool permissions, page IDs, or source positions.

## Source contract

- The memo id is `{{MEMO_ID}}` and its text length is `{{MEMO_LENGTH}}` JavaScript UTF-16 code units.
- Every observation and artifact MUST cite one or more exact half-open character spans `[start,end)` from this memo.
- `start >= 0`, `end > start`, and `end <= {{MEMO_LENGTH}}`.
- Mark model interpretation as `inference: true`; direct statements use `false`.
- A confidence score never substitutes for a source reference.

## Memo

{{MEMO_BODY}}

## Candidate pages

{{CANDIDATE_PAGES}}

## Required output

Return one JSON object with exactly these top-level keys:

```json
{
  "intent": {
    "kind": "emotion|task|idea|link|fact|question|work_log|continuation|other",
    "confidence": 0.0,
    "rationale": "brief classification reason"
  },
  "response_policy": {
    "mode": "silent|light|reflect|act",
    "reason_codes": ["one_or_more_stable_codes"],
    "uncertainty": 0.0,
    "max_reply_tokens": 0
  },
  "context_decision": {
    "strategy": "none|recent|semantic|hybrid",
    "query_terms": [],
    "candidates": [
      {"page_id":"candidate UUID","selected":true,"reason":"why it is or is not useful"}
    ],
    "selected_page_ids": ["selected candidate UUID"]
  },
  "response": {
    "body_md": "user-visible response",
    "claims": [
      {
        "text": "one claim from the response",
        "source_refs": [{"memo_id":"{{MEMO_ID}}","start":0,"end":1}],
        "inference": false
      }
    ],
    "suggested_followups": []
  },
  "summary": "short grounded summary",
  "observations": [
    {
      "kind": "fact|relation|task|conflict|inference",
      "subject": "string",
      "predicate": "string",
      "value": "any JSON value",
      "confidence": 0.0,
      "inference": false,
      "source_refs": [{"memo_id":"{{MEMO_ID}}","start":0,"end":1}]
    }
  ],
  "artifacts": [
    {
      "kind": "daily_contribution|page_patch",
      "schema_version": 1,
      "logical_key": "optional stable semantic key",
      "payload": {},
      "body_md": null,
      "source_refs": [{"memo_id":"{{MEMO_ID}}","start":0,"end":1}]
    }
  ],
  "proposed_actions": [
    {
      "tool": "calendar.create_event",
      "arguments": {},
      "effect": "external_write",
      "approval": "required",
      "rationale": "why this might help"
    }
  ],
  "proposed_memory_updates": [
    {
      "kind": "fact|preference|decision|person_state|working_context",
      "subject": "string",
      "predicate": "string",
      "value": "any JSON value",
      "confidence": 0.0,
      "source_refs": [{"memo_id":"{{MEMO_ID}}","start":0,"end":1}],
      "requires_confirmation": true,
      "rationale": "why this may deserve long-term memory"
    }
  ]
}
```

Rules:

- Choose the least intrusive response mode that still creates value:
  - `silent`: background organization only; set `response` to `null` and `max_reply_tokens` to `0`.
  - `light`: one short acknowledgement, clarification, or suggestion.
  - `reflect`: analysis, a useful question, or a grounded connection to prior notes.
  - `act`: answer, research, or one or more concrete action proposals.
- Non-silent modes MUST return a non-null `response`; silent MUST return `null`.
- Include every supplied candidate page exactly once in `context_decision.candidates`. Never return an unknown page id.
- `selected_page_ids` must exactly match candidates whose `selected` value is true.
- Select no context when it is not needed. Do not mention irrelevant retrieved pages merely because they were supplied.
- Every factual claim in `response.claims` must cite the memo. Interpretive or advisory text may use an empty `source_refs` array but must set `inference: true`.
- Always emit one `daily_contribution` artifact with payload `{headline, details, open_loops}`.
- A `page_patch` must use payload `{page_id, expected_version, title, contribution_md, rationale}` for an existing candidate, or `{slug, type, title, body_md, rationale}` for a new page.
- Existing `page_id` and `expected_version` must exactly match a candidate above.
- Prefer a concise appendable `contribution_md` over rewriting a candidate's entire body.
- External writes are proposals only and always use `approval: "required"`.
- Every long-term Memory change is a proposal with `requires_confirmation: true`; never present it as already saved.
- Do not propose an action unless the memo clearly asks for or strongly implies it.
- At most 20 observations, 5 artifacts, 3 proposed actions, and 3 Memory proposals.
