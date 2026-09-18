# What the side-engine is asked, and exactly how

A 2B model is not a small 35B. It is a capable text worker that fails in one
specific way, and the failure is not knowledge — it is composition.

Measured on the same facts, the same context and the same model:

| task shape | result |
| --- | --- |
| "return the parts of this fact the person stated" | 0 of 12 composites handled; 38 of 47 answers were the input echoed back |
| "did the person state this clause?" — one clause, YES or NO | **92%** correct, 28 of 30 of the person's clauses kept, **7 of 8 model inventions rejected** |

The second run rejected all three inventions that closed the memory guard's
gate — a certificate written in chapter 63, records unlocked in chapter 64,
an inn rebuilt in chapter 65 — none of which the person ever wrote.

So the model could do the judgement the whole time. What it could not do was
hold a 1,500-character text, decompose a value into clauses, judge each one
and reassemble the survivors, in a single generation. And the prompt made
failing easy by offering "repeat the whole value" as a legal answer, which
is the branch that needs no analysis.

## The five rules every prompt here follows

1. **One decision per call.** Never "judge these and return the good ones".
   Judge one thing; the caller composes.
2. **A closed answer set.** YES/NO, or one word from a named list. Never
   free text where a decision is wanted.
3. **No lazy branch.** If "repeat the input" or "reply NONE" is a legal
   answer, a small model under uncertainty will take it. Every answer must
   cost the same.
4. **Give the whole fact.** The key carries the claim as often as the value
   does: `rules/marcus_must_not_learn_photo_before_chapter_60 = true` is
   meaningless without its key. Withholding it halved accuracy, measured.
5. **Say what not to do.** Explain, hedge, quote, apologise, add a preamble
   — each is a failure mode worth one sentence of prohibition.

## The tasks

Each is a separate call with its own prompt. `T1` is measured; the rest are
designed to the same shape and are measured by
`benchmark/side_engine_tasks.py`.

| # | Task | Question | Answer | What it is for |
| --- | --- | --- | --- | --- |
| T1 | Clause attribution | did the person state this clause? | YES / NO | splitting a composite; refusing authority to an invented half |
| T2 | Durability | is this worth remembering after the session? | YES / NO | filtering what consolidation stores |
| T3 | Contradiction | do these two statements disagree? | YES / NO | catching a conflict the fold-equality check misses |
| T4 | Supersession | is the new one an update, or a disagreement? | UPDATE / CONFLICT | versioning versus disputing |
| T5 | Duplication | do these two facts say the same thing? | YES / NO | stopping near-duplicate keys |
| T6 | Reply check | does this reply contradict this stored fact? | YES / NO | the shadow: catching the big model contradicting the store |
| T7 | Retrieval | could this fact answer this question? | YES / NO | ranking keys without a full search |

Every one is a yes/no or a two-way choice over a *single* pair. Nothing in
this table asks the model to produce a list, rewrite a value, or decide how
many of something there are — the three shapes it demonstrably cannot do.

### T1 — clause attribution *(measured: 92%)*

```
system: You decide whether one statement came from the person or not.
        Answer with exactly one word: YES or NO.
        YES means the person wrote it or clearly implied it.
        NO means it does not appear in what they wrote, however true it
        might be.
        Do not explain. Do not quote. Do not answer with anything but YES
        or NO.

user:   WHAT THE PERSON WROTE:
        {the person's own words}

        STATEMENT: {key} = {one clause}
        Did the person state this?
```

### T2 — durability

```
system: You decide whether one fact is worth keeping after this session
        ends. Answer with exactly one word: YES or NO.
        YES for decisions and the reasons behind them, fixed attributes,
        rules, constraints, and current state.
        NO for conversation, reasoning, code, anything a later session can
        work out for itself, and anything true only right now.
        Do not explain. Answer with one word.

user:   FACT: {key} = {value}
        Keep it?
```

### T3 — contradiction

```
system: You decide whether two statements disagree. Answer with exactly
        one word: YES or NO.
        YES means both cannot be true at once.
        NO means they can both be true, including when they are about
        different things, or when one simply says more than the other.
        Different wording for the same thing is NO.
        Do not explain. Answer with one word.

user:   A: {stored key} = {stored value}
        B: {incoming key} = {incoming value}
        Do A and B disagree?
```

### T4 — supersession

```
system: Something has changed about one fact. You decide which kind of
        change it is. Answer with exactly one word: UPDATE or CONFLICT.
        UPDATE means the world moved on and B is the newer state.
        CONFLICT means B contradicts A about the same moment, and one of
        them is wrong.
        Do not explain. Answer with one word.

user:   EARLIER: {key} = {old value}
        NOW:     {key} = {new value}
        Which is it?
```

### T5 — duplication

```
system: You decide whether two facts say the same thing. Answer with
        exactly one word: YES or NO.
        YES means a reader learns nothing from the second that the first
        did not already tell them.
        NO means the second adds something, or is about something else.
        Do not explain. Answer with one word.

user:   A: {key a} = {value a}
        B: {key b} = {value b}
        Same fact?
```

### T6 — reply check

```
system: You check one reply against one thing that is known. Answer with
        exactly one word: YES or NO.
        YES means the reply says something that cannot be true if the
        known fact is true.
        NO means it agrees, or does not touch on it at all.
        Silence is not a contradiction.
        Do not explain. Answer with one word.

user:   KNOWN: {key} = {value}
        REPLY: {the assistant's reply}
        Does the reply contradict what is known?
```

### T7 — retrieval

```
system: You decide whether one stored fact could answer one question.
        Answer with exactly one word: YES or NO.
        YES means the fact contains the answer, or part of it.
        NO means it does not, even if it is about the same subject.
        Do not explain. Answer with one word.

user:   QUESTION: {the question}
        FACT: {key} = {value}
        Could this fact answer it?
```

## How each one is judged

`benchmark/side_engine_tasks.py` runs every task over labelled cases drawn
from the recorded runs, and reports accuracy split by the answer that was
correct — because a model that always says NO scores well on a set that is
mostly NO, and that is exactly the failure mode of a small model with a lazy
branch.

A task ships only when both halves are good. One-sided accuracy is the shape
of a model that is not reading the question.

## What the measurement found — 2026-09-18

Run over the 60 cases the script can build here, greedy, through
`TinyTitanBench cpu35batch`. T1 is not in this run: its cases come from the
memory guard's recorded journals, which this checkout does not carry, so T1
keeps its 92% from 2026-09-11.

**The 2B is not the instrument.** A first pass on it said T5 was one-sided and
T7 nearly so, and both of those are wrong about the task — a 4B decides them.
So the shipped (v1) prompts were run at all three sizes, and the second draft
(v2) on the 4B:

```bash
python3.13 benchmark/side_engine_tasks.py --prepare /tmp/jobs.jsonl
.build/release/TinyTitanBench cpu35batch models/qwen3.5_4B_4Bit /tmp/jobs.jsonl /tmp/done.jsonl
python3.13 benchmark/side_engine_tasks.py --score /tmp/done.jsonl
```

Half A is the answer that says yes to the question (UPDATE for T4); half B is
the one that says no (CONFLICT for T4). A task is ready only when both halves
are good.

| task | 2B v1 | 4B v1 | 4B v2 | 9B v1 |
| --- | --- | --- | --- | --- |
| T2 durability | 55% (10/10, 1/10) | 45% (9/10, 0/10) | 70% (10/10, 4/10) | 50% (10/10, 0/10) |
| T3 contradiction | 100% (5/5, 5/5) | 100% (5/5, 5/5) | 100% (5/5, 5/5) | 100% (5/5, 5/5) |
| T4 supersession | 50% (3/3, 0/3) | 50% (3/3, 0/3) | 67% (1/3, 3/3) | 50% (3/3, 0/3) |
| T5 duplication | 50% (0/4, 4/4) | 100% (4/4, 4/4) | 100% (4/4, 4/4) | 100% (4/4, 4/4) |
| T6 reply check | 62% (0/3, 5/5) | 62% (0/3, 5/5) | 75% (1/3, 5/5) | 100% (3/3, 5/5) |
| T7 retrieval | 88% (3/4, 4/4) | 100% (4/4, 4/4) | 100% (4/4, 4/4) | 100% (4/4, 4/4) |

Read down the columns. T3 is good at every size. T5 and T7 go from one-sided on
the 2B to perfect on the 4B and stay there. T6 needs the 9B: the 2B and the 4B
catch 0 of its 3 contradicting replies, the 9B all three. T2 and T4 are
one-sided at every size with the shipped prompts, which is a prompt problem
rather than a capacity one — and the second draft moves both without settling
either: T2's negative half goes from 0 of 10 to 4 of 10, and T4's added rule
line takes CONFLICT from 0 of 3 to 3 of 3 while UPDATE falls from 3 of 3 to 1 of
3, trading one one-sided answer for the other. (The 2B's own v2 run — T2 60%,
T4 17%, T5 100% — is in the history of `03d79f7`.)

**So the model is part of the result.** The 4B is the floor that decides
contradiction, duplication and retrieval; the 9B adds the reply check; the 2B
decides contradiction and nothing else of these five. Durability and
supersession are not ready on any of the three and must not be wired to a
caller. The sentence-rendered facts that earlier fixed T5 for the 2B are not
needed at the 4B, where the shipped `key = value` form already scores 100%.

Runs made 2026-09-18 with the release `TinyTitanBench` built from `036f98c`;
60 jobs, 7,276 tokens: 2B 386.2 s (18.8 tok/s), 4B 1,131.3 s (6.4), 4B v2
1,168.3 s (6.6), 9B 2,244.1 s (3.2).

## The case the wiring uses is not the case the matrix measured

The T5 rows above pair the **same key** with the same value. In the memory path
a same-key pair never reaches the engine — the deterministic fold-equality
check skips it first — so those rows say nothing about whether the wiring
works. What the wiring asks is a **new key** that says what an existing one
already said, and a new key whose value cannot both be true with an existing
one. That is measured separately, over 8 duplication and 4 contradiction pairs
built from the book's own facts, by
`benchmark/side_engine_wired_cases.py`:

| model | T5 (new key, same fact) | T3 (new key, disagreeing) |
| --- | --- | --- |
| 4B | 7/8 | 4/4 |
| 9B | 8/8 | 4/4 |

The 4B's one miss is `rules/ferry = runs only on Sundays` against
`rules/ferry_schedule = only Sundays`, which it kept as a second key — the safe
direction for suppression, since a missed duplicate leaves a redundant address
while a false positive would drop a fact. Runs made 2026-09-18: 4B, 12 prompts,
1,399 tokens in 183.1 s (7.6 tok/s); 9B the same cases in 359.7 s (3.9).

**And the order of the two facts is part of the prompt.** These cases put the
fact already in the store in `A` and the incoming one in `B`, and on the 4B the
same pair answers YES only in that order:

| pair | order | answer |
| --- | --- | --- |
| `characters/marcus/eyes = grey` vs `…/eye_colour = grey` | stored first | YES |
| the same pair | incoming first | **NO** |

So the port's `duplicates(_ stored:, _ new:)` fixes the order and the server
adapter maps `stored` to `A`. The first version of the wiring passed them the
other way round and would have stopped nothing: the stubs cannot see the
difference, and the release-only end-to-end test
(`theRealInstallAnswersThroughTheFactoryAndTheAdapter`) is what found it. Four
probe cases, 448 tokens, 58.0 s on the 4B.

## Where it is wired

The port is `MemorySideEngine`
(`sources/TinyTitanMemory/MemorySideEngine.swift`), and the server adapts
`SideEngine` to it (`sources/TinyTitanServer/Core/SideEngineService.swift`).
Only the tasks the matrix above says are ready have a method, and `nil` means
"no decision", so an engine that is absent, shut down, or confused leaves the
deterministic path exactly as it was.

The model is `TINYTITAN_SIDE_ENGINE` — an install name under
`--models-directory`, a directory, or `0` — and defaults to the 4B. The weights
load on the first judgement, and the width comes from the server's
`ServerCoordinator.generating` signal.

**Every question is a generation, so the number of them is budgeted.** Timed
over the wired cases, one judgement costs **15.2 s on the 4B** and **29.8 s on
the 9B** (12 cases in 183.1 s and 359.7 s, less the ~1.2 s load; a separate
2-case run on the 4B measured 31.5 s, which fits). A candidate loop per fact
would therefore cost minutes, so one consolidation may put
`MemoryService.maximumSideEngineQuestions` (4) questions in total and at most
`maximumQuestionsPerFact` (2) to any one fact — about a minute on the 4B, in the
pause consolidation already runs in.

Wired:

- **T5 duplication** and **T3 contradiction**, in consolidation, for facts in
  the session's own scope and in the shared workspace. A new key whose content
  an existing key in the same leading segment already carries is not stored, and
  the log names both keys. A new key that cannot both be true with an existing
  one is logged as a possible conflict and otherwise left alone: advisory by
  design, because disagreement is not supersession and T4, which would tell them
  apart, is one-sided at every measured size.

Not wired:

- **T7 retrieval.** It is ready — 100% at the 4B on the benchmark's cases — but
  its only caller would be `memory_search`, a tool call the client's turn waits
  on. At ~15 s a judgement that is up to a minute added to an interactive turn,
  the opposite of the side-engine's design (concurrent, one thread, 3% to the
  generation it overlaps). It stays on the port for a caller that can afford it:
  an offline recall experiment, or a background pre-rank.
- **T6 reply check** becomes available when the engine is a 9B.
