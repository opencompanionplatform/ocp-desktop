extends SceneTree

const ChunkerScript = preload("res://scripts/runtime_v3/services/sentence_chunker.gd")


func _initialize() -> void:
	var chunker := ChunkerScript.new()
	var first := chunker.take_ready("Hello there. This is still", false)
	var second := chunker.take_ready("Hello there. This is still streaming", false)
	var duplicate := chunker.take_ready("Hello there. This is still streaming", false)
	var final_chunks := chunker.take_ready("Hello there. This is still streaming", true)
	var english_ok := first.size() == 1 \
		and first[0] == "Hello there." \
		and second.is_empty() \
		and duplicate.is_empty() \
		and final_chunks.size() == 1 \
		and final_chunks[0] == "This is still streaming"

	chunker.reset()
	var thai_text := "วันนี้เราจะวางแผนงานให้เป็นขั้นตอนเพื่อให้ทำตามได้ง่ายและไม่ต้องรีบตัดสินใจทุกอย่างในครั้งเดียว"
	var thai_stream := chunker.take_ready(thai_text, false)
	var thai_final := chunker.take_ready(thai_text, true)
	var rebuilt_thai := "".join(thai_stream) + "".join(thai_final)
	var thai_ok := thai_stream.size() == 1 \
		and thai_stream[0].length() >= 72 \
		and rebuilt_thai == thai_text

	chunker.reset()
	var unicode_partial := chunker.take_ready("สวัสดีครับ", false)
	var unicode_final := chunker.take_ready("สวัสดีครับ 😊", true)
	var unicode_ok := unicode_partial.is_empty() \
		and unicode_final.size() == 1 \
		and unicode_final[0] == "สวัสดีครับ 😊"

	chunker.reset()
	var paused_short := chunker.take_ready("สวัสดีครับ", false, true)
	var paused_thai := chunker.take_ready("สวัสดีครับ วันนี้มีอะไรให้ช่วยไหมครับ", false, true)
	var paused_duplicate := chunker.take_ready("สวัสดีครับ วันนี้มีอะไรให้ช่วยไหมครับ", false, true)
	var paused_ok := paused_short.is_empty() \
		and paused_thai.size() == 1 \
		and paused_thai[0] == "สวัสดีครับ วันนี้มีอะไรให้ช่วยไหมครับ" \
		and paused_duplicate.is_empty()

	var ok := english_ok and thai_ok and unicode_ok and paused_ok
	print("[CHAT-P2.2-CHUNK] english=", english_ok, " thai=", thai_ok, " unicode=", unicode_ok, " paused=", paused_ok, " first=", first, " final=", final_chunks)
	quit(0 if ok else 1)
