package openai

import (
	"testing"

	"github.com/maximhq/bifrost/core/schemas"
)

func TestStripDSMLFromStreamDeltaWithBuffer(t *testing.T) {
	tests := []struct {
		name           string
		deltas         []string
		expectedSupp   []bool
		expectedResult []bool // true if suppressed
	}{
		{
			name:   "Single delta with marker",
			deltas: []string{"<｜DSML｜>"},
			expectedSupp: []bool{true},
			expectedResult: []bool{true},
		},
		{
			name:   "Split marker across two deltas",
			deltas: []string{"<｜DS", "ML｜>"},
			expectedSupp: []bool{false, true},
			expectedResult: []bool{false, true},
		},
		{
			name:   "Split marker across three deltas",
			deltas: []string{"<｜", "DSML", "｜>"},
			expectedSupp: []bool{false, false, true},
			expectedResult: []bool{false, false, true},
		},
		{
			name:   "Marker with preceding text",
			deltas: []string{"some text <｜D", "SML｜> more text"},
			expectedSupp: []bool{false, true},
			expectedResult: []bool{false, true},
		},
		{
			name:   "No marker",
			deltas: []string{"just some", "normal text"},
			expectedSupp: []bool{false, false},
			expectedResult: []bool{false, false},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			buffer := ""
			for i, content := range tt.deltas {
				delta := &schemas.ChatStreamResponseChoiceDelta{
					Content: &content,
				}
				suppressed := stripDSMLFromStreamDeltaWithBuffer(delta, &buffer)
				if suppressed != tt.expectedSupp[i] {
					t.Errorf("delta %d: expected suppressed %v, got %v", i, tt.expectedSupp[i], suppressed)
				}
				if tt.expectedSupp[i] && delta.Content != nil {
					t.Errorf("delta %d: expected Content to be nil", i)
				}
				if !tt.expectedSupp[i] && (delta.Content == nil || *delta.Content != content) {
					t.Errorf("delta %d: expected Content to be preserved", i)
				}
			}
		})
	}
}
