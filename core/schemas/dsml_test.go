package schemas

import (
	"testing"
)

func TestStripDeepSeekMarkersWithState(t *testing.T) {
	tests := []struct {
		name           string
		deltas         []string
		expectedSupp   []bool
		expectedResult []string
	}{
		{
			name:           "Single delta with marker",
			deltas:         []string{"<｜DSML｜>"},
			expectedSupp:   []bool{true},
			expectedResult: []string{""},
		},
		{
			name:           "Split marker across two deltas",
			deltas:         []string{"<｜DS", "ML｜>"},
			expectedSupp:   []bool{false, true},
			expectedResult: []string{"", ""},
		},
		{
			name:           "Split marker across three deltas",
			deltas:         []string{"<｜", "DSML", "｜>"},
			expectedSupp:   []bool{false, false, true},
			expectedResult: []string{"", "DSML", ""},
		},
		{
			name:           "Marker with preceding text",
			deltas:         []string{"some text <｜D", "SML｜> more text"},
			expectedSupp:   []bool{false, true},
			expectedResult: []string{"some text ", ""},
		},
		{
			name:           "No marker",
			deltas:         []string{"just some", "normal text"},
			expectedSupp:   []bool{false, false},
			expectedResult: []string{"just some", "normal text"},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			buffer := ""
			suppressed := false
			for i, content := range tt.deltas {
				result := StripDeepSeekMarkersWithState(content, &buffer, &suppressed)
				if suppressed != tt.expectedSupp[i] {
					t.Errorf("delta %d: expected suppressed %v, got %v", i, tt.expectedSupp[i], suppressed)
				}
				if result != tt.expectedResult[i] {
					t.Errorf("delta %d: expected result %q, got %q", i, tt.expectedResult[i], result)
				}
			}
		})
	}
}

func TestStripDeepSeekMarkers(t *testing.T) {
	tests := []struct {
		input    string
		expected string
	}{
		{"hello world", "hello world"},
		{"<｜DSML｜function_calls>{}", ""},
		{"some text <｜DSML｜", "some text "},
		{"<｜function_call>call()<｜DSML｜", ""},
		{"Multiple markers <｜function_call> one <｜function_call> two", "Multiple markers "},
	}

	for _, tt := range tests {
		t.Run(tt.input, func(t *testing.T) {
			result := StripDeepSeekMarkers(tt.input)
			if result != tt.expected {
				t.Errorf("expected %q, got %q", tt.expected, result)
			}
		})
	}
}
