package pointer

func String(s string) *string {
	return &s
}

func Int(i int) *int {
	return &i
}

func Int64(i int64) *int64 {
	return &i
}

func Bool(b bool) *bool {
	return &b
}
