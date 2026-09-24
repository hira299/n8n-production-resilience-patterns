# Defensive handling of LLM output

## The failure

A workflow asks a model for JSON and passes the result straight to the next node. Most of the time it works. Then the model wraps the JSON in a markdown fence, returns one object where an array was expected, stops mid-string because it hit a token limit, answers in prose, or invents a field name. The next node throws, and in a batch, one bad response stops every item after it.

Structured output modes (JSON mode, response schemas) reduce these failures a lot. They do not remove the need to check the result: truncation still happens, and a syntactically valid response can still have the wrong fields or values.

## Where this comes from

My Competitor Intelligence & SEO pipeline had a parser node between the Gemini call and task creation. It looked for the text in the places different model nodes put it, stripped markdown fences, accepted a single object as a one-item array, and threw a clear error if the result still was not valid JSON.

Elsewhere in my own work I found the opposite: an IF node whose condition was `JSON.parse($json.choices[0].message.content).classification`, with no guard. Any malformed response makes that expression throw, and the error names the IF node rather than the model, which sends debugging in the wrong direction.

## The pattern

The [example](../../examples/ai-output-validation/defensive-llm-json-parser.json) keeps the original parser's steps and adds two things:

1. **Field-level validation.** Required fields and types are checked, and enumerated values (here, `search_intent`) must be from an allowed set.
2. **A verdict instead of an exception.** The node returns `{ valid, errors, records }` for every item. Valid items continue; invalid ones go to the dead-letter queue with the reasons and a short preview of the raw output. One bad response no longer stops the batch.

It runs six simulated outputs covering the common failure shapes: clean, fenced, single object, truncated, prose, and wrong fields. The first three are accepted and the last three rejected. Replace the simulation node with your model node.

## Practical rules

- **Parse in a Code node, never in an expression.** Expressions cannot handle errors, and their failures point at the wrong node.
- **Validate meaning, not only syntax.** Parsed JSON with the wrong keys is still a failure.
- **Keep the raw output,** truncated, with the rejection. You will need it to tell prompt problems from model problems.
- **Retry sparingly.** A retry with the same prompt often succeeds for truncation or formatting failures, but not for systematic ones. Cap retries, then dead-letter.
- **Never let the model decide whether its own output is acceptable.** The check has to be outside the model: code, a schema, or a separate verifier.

## Limits

Validation catches output that is malformed or outside the expected shape. It cannot tell whether well-formed content is true or appropriate: a valid JSON object can still contain a wrong keyword or a made-up fact. For that you need grounding in real data, human review, or a domain-specific verifier. Validation makes failures visible; it does not make a model correct.
