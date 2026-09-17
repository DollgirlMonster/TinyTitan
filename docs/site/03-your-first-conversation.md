# Your first conversation

The build is done and a model is on disk. Let's make it say something.

There are two doors into TinyTitan, and they use the same engine. Pick whichever
sounds like you.

- **The server, with a client** — start the model once, then talk to it from an
  app. This is the closest thing to an ordinary chat window, and the launcher
  does the wiring for you. Start here.
- **One question from the Terminal** — a single command, a single prompt, an
  answer, with no server running at all. Start here if you want the shortest
  path to seeing it work.

## Door one: the server, and a client

Start the server first. If you just ran the installer and said yes when it
offered to start the server, that is already done — skip ahead to the base URL.
Otherwise, in the Terminal:

```bash
~/.local/bin/tinytitan
```

The installer put that command there. If it is not on your `PATH`, this is the
same launcher by the path inside your checkout:

```bash
~/TinyTitan/tools/server_launcher.sh
```

It asks a few questions in plain language and **every question has a default**,
so pressing Enter through them all gives you the recommended setup. By default
it starts the server alone. If you already use **Codex, Claude Code, Qwen Code,
OpenCode, or the Zed editor**, name that app when it asks and it writes the
app's settings and opens it for you — that is the least-typing path. Zed is the
most window-like of the five: a graphical editor with a chat panel you type
into.

If you use none of those, there is no TinyTitan window of its own to fall back
on. That is the honest gap a server-first product leaves: your first answer is
the `curl` request below or door two, and a client is something you add later.
Everything works the same once one is connected.

The first thing that happens is the slow thing: the model has to load from
disk into memory. On the 35B models that is a wait of tens of seconds, and the
launcher tells you it is working. That delay is the price of a model this
size running locally, and it happens once per launch, not once per question.

Once it says **"TinyTitanServer ready"**, it prints the address your client
should use:

```
Base URL:   http://127.0.0.1:8080/v1
API key:    any value (the server does not authenticate)
```

Leave that Terminal window open while you use TinyTitan — the launcher *is* the
server, and `Ctrl-C` in it stops the model. Point your client at the base URL,
type a question, and send it. Try something ordinary to start:

> Explain what a mutex is, as if I have never programmed.

You will see the answer appear a few words at a time. That streaming is
normal — it is the model generating, not a download.

**No client to point at it?** The smallest one is `curl`, and it needs nothing
installed. With the server running, paste this (use the model ID the launcher
printed — the `_8-Bit` or `_4-Bit` ending matters):

```bash
curl --silent http://127.0.0.1:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "ornith-1.5-35b-a3b_8-Bit",
    "messages": [{"role": "user", "content": "Explain what a mutex is, as if I have never programmed."}],
    "temperature": 0,
    "max_completion_tokens": 256
  }'
```

That is a Terminal command, and it prints raw JSON rather than a tidy window.
It is the honest smallest step — nothing to install, nothing to configure — and
it proves the server works before you spend time setting up a client.
[Connecting your apps](06-connecting-your-apps.md) has the full client setups.

**Two things worth knowing immediately:**

- **It is only as fast as it is.** On a 24 GB M-series Mac, expect the 35B
  models at roughly 20 tokens a second in 4-bit or about 12 in 8-bit, and the
  125B model at about 5. If you are used to cloud chatbots, this will feel
  slower, and that is the honest trade: nothing leaves your machine, and
  nothing is metered.
- **One model at a time.** If a second TinyTitan process is already running, they
  will fight over memory. Stop one first.

### The choices you will actually meet

Defaults are sane, so you can accept every question the launcher asks. The ones
worth knowing on day one:

| Choice | Where you meet it | What it does |
| --- | --- | --- |
| **Model** | A launcher question; `--model` | Which installed model to load. Once the server runs, every installed model is also reachable by name. |
| **Thinking** | A launcher question; `--thinking` | Whether the model reasons before it answers. See below. |
| **Context length** | A launcher question; `--context` | How much conversation the model can "hold" at once. Bigger costs more memory. |
| **Concise answers** | A launcher question; `--answers concise` | Strips the polite preamble and closing summary. |
| **Temperature** | In your client, or `--temperature` on the one-shot CLI | Lower is more literal and repeatable; higher is more varied. |

There is no wrong setting to begin with. When you want to tune, read
[The dials](05-the-dials.md) — it explains each one, including the ones you
should probably leave alone.

### A word about "thinking"

Some models can reason at length before answering. It genuinely helps with
hard questions — a tricky bug, a piece of analysis — and genuinely wastes
your time on easy ones.

TinyTitan only offers the thinking controls each model's own template actually
implements. That is deliberate: with thinking off it answers directly, and it
will not invent "low/medium/high effort" modes for a model that does not have
them. If you want the details of which model offers what, that is
[Choosing a model](04-choosing-a-model.md).

For a first session, leave thinking **off**. You get the answer faster, and
you will see exactly what the model does with no help.

## Door two: one question, one command

If you do not want a conversation, the one-shot CLI answers a single prompt
without a server at all. This is the simplest possible thing that works:

```bash
.build/release/TinyTitanCLI \
  --model models/ornith-1.5_35B_A3B_8Bit \
  --prompt "The capital of France is" \
  --max-new 32 \
  --temperature 0
```

Run it from inside the `TinyTitan` folder (article 02 leaves you there). Text
goes to standard output; the timing and token count go to standard
error. `--temperature 0` means "always pick the most likely next token", so
the same prompt gives the same answer every time — useful when you are
testing whether something changed.

A few flags worth meeting early:

- `--max-new 64` — stop after 64 new tokens instead of rambling on.
- `--quiet` — hide the timing footer.
- `--messages-file chat.json` — send a proper chat conversation (a JSON list
  of `role` and `content`) instead of a raw prompt.

**If you want to talk to it like a chat assistant**, use door one: the server
and a client. [Connecting your apps](06-connecting-your-apps.md) sets that up,
and it is genuinely the best way to use TinyTitan day to day.

## Whichever you chose, the model is the same

The CLI and the server run the same weights with the same engine. The server
adds convenience: one model loaded once, every installed model reachable by
name, and an API your own apps can call. Nothing is second-class.

## When it does not answer

| What you see | What to check |
| --- | --- |
| It sits "loading" for minutes | Normal for the first load of a large model; watch free memory |
| It starts, then dies | Another model process may be running — stop it and retry |
| The server is up but a client gets a 404 | The model ID must carry its `_4-Bit` or `_8-Bit` ending — ask `/v1/models`; see [Connecting your apps](06-connecting-your-apps.md) |
| Very slow, machine sluggish | Free up memory, or pick a smaller model — [Choosing a model](04-choosing-a-model.md) |
| Nonsense or repeated text | Lower the temperature; see [The dials](05-the-dials.md) |

And genuinely: ask on the forum. Include which model, how you started the
server, and which client you used — that is usually enough for someone to spot
it.

## Where to go next

You have it answering. The next real decision is which model you are running
and why → **[Choosing a model](04-choosing-a-model.md)**

*TinyTitan 5.1 at the time of writing. Speed figures come from the project's
published benchmarks on a base 8-core M3 with 24 GB; your Mac will differ.*
