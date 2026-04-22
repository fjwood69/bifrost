package openai

import (
	"strings"

	"github.com/maximhq/bifrost/core/schemas"
)

// dsmlMarker is the prefix that identifies DeepSeek DSML tool call blocks.
// DeepSeek's native format uses U+FF5C (FULLWIDTH VERTICAL LINE) as delimiters:
//
//	<｜DSML｜function_calls ...>
//	<｜function_call> ... </｜function_call>
//
// When routing DeepSeek via an OpenAI-compat endpoint (e.g. Parasail), these
// markers can appear in the text content field alongside proper tool_calls in
// the structured ToolCalls array.  Forwarding them verbatim causes the raw
// DSML XML to leak into client responses.
const dsmlMarker = "<｜DSML｜"

// stripDSMLFromStreamDelta nils out the Content pointer of a streaming delta
// if it contains a DSML marker.  The structured ToolCalls array is untouched
// so that properly-formatted tool calls are still forwarded.
// stripDSMLFromStreamDelta nils out Content if it contains a DSML marker
// and returns true so the caller can suppress subsequent text deltas.
func stripDSMLFromStreamDelta(delta *schemas.ChatStreamResponseChoiceDelta) bool {
	if delta == nil || delta.Content == nil {
		return false
	}
	if strings.Contains(*delta.Content, dsmlMarker) {
		delta.Content = nil
		return true
	}
	return false
}

// stripDSMLFromStreamDeltaWithBuffer nils out Content if the combination of the current
// delta and a provided rolling buffer contains a DSML marker. It updates the buffer
// with the tail of the current content to catch split markers in subsequent deltas.
func stripDSMLFromStreamDeltaWithBuffer(delta *schemas.ChatStreamResponseChoiceDelta, buffer *string) bool {
	if delta == nil || delta.Content == nil {
		return false
	}

	// Append current content to buffer
	full := *buffer + *delta.Content

	if strings.Contains(full, dsmlMarker) {
		delta.Content = nil
		*buffer = "" // Clear buffer once detected
		return true
	}

	// Keep only the last 20 bytes to catch split markers in the next delta.
	// The marker "<｜DSML｜" is 11 bytes in UTF-8.
	const maxBufferLen = 20
	if len(full) > maxBufferLen {
		*buffer = full[len(full)-maxBufferLen:]
	} else {
		*buffer = full
	}

	return false
}

// stripDSMLFromChatResponse strips DSML markers from assistant message content
// strings in a non-streaming response choice.  The ToolCalls array is untouched.
func stripDSMLFromChatResponse(choice *schemas.BifrostResponseChoice) {
	if choice == nil || choice.ChatNonStreamResponseChoice == nil {
		return
	}
	msg := choice.ChatNonStreamResponseChoice.Message
	if msg == nil || msg.Content == nil || msg.Content.ContentStr == nil {
		return
	}
	if strings.Contains(*msg.Content.ContentStr, dsmlMarker) {
		msg.Content.ContentStr = nil
	}
}
