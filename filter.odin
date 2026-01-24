package filewatch

Filter :: struct {
	events: [Target]Event_Filter,
	globs:  Glob,
}

Event_Filter_Flags :: enum {
	.Create,
	.Modify,
	.Delete,
	.Move,
}
Event_Filter :: bit_set[Event_Filter_Flags]

