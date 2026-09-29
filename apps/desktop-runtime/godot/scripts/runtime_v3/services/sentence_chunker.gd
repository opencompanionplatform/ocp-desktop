extends RefCounted
class_name RuntimeV3SentenceChunker

## Incremental phrase/sentence chunker for streaming TTS. It consumes the full
## accumulated assistant text and only returns text that has become stable
## enough to synthesize. Finalization flushes any remaining tail.

# Start speech sooner for long streaming replies without chopping very short
# phrases. Sentence punctuation still wins; the soft limit is only the fallback.
const HARD_LIMIT := 120
const SOFT_LIMIT := 72
const MIN_PHRASE := 20
const PAUSE_PHRASE_MIN := 24

var committed_chars := 0


func reset() -> void:
	committed_chars = 0


func take_ready(full_text: String, final: bool = false, stable_pause: bool = false) -> Array[String]:
	var chunks: Array[String] = []
	if full_text.length() <= committed_chars:
		return chunks

	while committed_chars < full_text.length():
		var remaining := full_text.substr(committed_chars)
		var boundary := _stable_boundary(remaining, final, stable_pause)
		if boundary <= 0:
			break
		var chunk := remaining.substr(0, boundary).strip_edges()
		committed_chars += boundary
		while committed_chars < full_text.length() and full_text[committed_chars] in [" ", "\t", "\r", "\n"]:
			committed_chars += 1
		if not chunk.is_empty():
			chunks.append(chunk)
		if not final and committed_chars >= full_text.length():
			break
	return chunks


func _stable_boundary(text: String, final: bool, stable_pause: bool = false) -> int:
	if text.is_empty():
		return 0

	var sentence_boundary := _first_sentence_boundary(text)
	if sentence_boundary > 0:
		return sentence_boundary

	if text.length() >= HARD_LIMIT:
		var soft_cut := _last_break_before(text, HARD_LIMIT)
		if soft_cut >= MIN_PHRASE:
			return soft_cut
		return _safe_unicode_boundary(text, HARD_LIMIT)

	if text.length() >= SOFT_LIMIT:
		var phrase_cut := _last_phrase_break(text)
		if phrase_cut >= MIN_PHRASE:
			return phrase_cut
		# Thai commonly has no spaces between words. Waiting until the hard limit
		# makes first voice unnecessarily late, so use a Unicode-safe soft bound.
		return _safe_unicode_boundary(text, SOFT_LIMIT)

	# A provider pause is a stronger stability signal than raw token arrival.
	# It lets short punctuation-free Thai phrases start voice before finalization
	# while the minimum prevents slow token streams from becoming word fragments.
	if stable_pause and text.length() >= PAUSE_PHRASE_MIN:
		return _safe_unicode_boundary(text, text.length())

	return text.length() if final else 0


func _first_sentence_boundary(text: String) -> int:
	for index in range(text.length()):
		var ch := text[index]
		if ch in [".", "!", "?", "。", "！", "？", "…", "ฯ", "\n"]:
			return index + 1
	return 0


func _last_phrase_break(text: String) -> int:
	var limit := mini(text.length(), HARD_LIMIT)
	for index in range(limit - 1, MIN_PHRASE - 1, -1):
		if text[index] in [",", ";", ":", "，", "、"]:
			return index + 1
	return _last_break_before(text, limit)


func _last_break_before(text: String, limit: int) -> int:
	var capped := mini(text.length(), limit)
	for index in range(capped - 1, MIN_PHRASE - 1, -1):
		if text[index] in [" ", "\t", "\n"]:
			return index + 1
	return 0


func _safe_unicode_boundary(text: String, requested: int) -> int:
	var boundary := clampi(requested, 1, text.length())
	# Do not leave Thai/Unicode combining marks or variation selectors detached
	# from their base character. Advancing is bounded by the short continuation
	# run and preserves every code point for the next committed offset.
	while boundary < text.length() and _is_continuation(text.unicode_at(boundary)):
		boundary += 1
	if boundary < text.length() and text.unicode_at(boundary - 1) == 0x200D:
		boundary += 1
		while boundary < text.length() and _is_continuation(text.unicode_at(boundary)):
			boundary += 1
	return boundary


func _is_continuation(code: int) -> bool:
	return (code >= 0x0300 and code <= 0x036F) \
		or code == 0x0E31 \
		or (code >= 0x0E34 and code <= 0x0E3A) \
		or (code >= 0x0E47 and code <= 0x0E4E) \
		or (code >= 0xFE00 and code <= 0xFE0F) \
		or (code >= 0x1F3FB and code <= 0x1F3FF)
