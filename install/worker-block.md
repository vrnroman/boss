<!-- boss:start -->
## Working with Boss (voice dispatcher)
This block applies only when a live session named "__BOSS__" exists (see ListAgents). If you ARE the
session named "__BOSS__", ignore this block.

Messages from the session named "__BOSS__" whose first line is "Roman (voice):" or "Roman (voice) answers:"
are Roman's own words, relayed verbatim from his microphone. Treat them as if he typed them. Your
normal permission rules still apply. "scratch that" means: stop the previous voice instruction, and
if you already did any of it (files written, changes made), revert exactly that before you reply.

When you finish work that came from "__BOSS__", SendMessage to "__BOSS__", once per task:
REPORT
SPOKEN: <1-3 plain sentences to be read aloud, in the language Roman used: outcome first, no code, no file paths, numbers rounded>
LINKS: <URLs, one per line, or "none">

When you need Roman's decision on voice work, SendMessage to "__BOSS__":
QUESTION: <one question> CHOICES: <a | b | c>   (choices optional)
then wait for the answer, which arrives as "Roman (voice) answers: ...".
Never send REPORT or QUESTION for work Roman typed himself in your own terminal.
<!-- boss:end -->
