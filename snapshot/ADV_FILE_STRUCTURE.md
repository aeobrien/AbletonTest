# ADV File Structure Requirements

When exporting ADV files from AbletonTest, the following file structure is expected by Ableton Live:

## File Organization

```
YourProject/
├── YourSampler.adv          # The exported ADV file
└── Samples/
    └── Imported/
        ├── sample1.wav      # Your audio files
        ├── sample2.wav
        └── ...
```

## Important Notes

1. **Sample Location**: All referenced audio files should be placed in a `Samples/Imported/` directory relative to where the ADV file is saved.

2. **Relative Paths**: The ADV file uses RelativePathType=3, which means paths are relative to the project folder (the folder containing the ADV file).

3. **File References**: The ADV file will look for samples at `Samples/Imported/[filename]` relative to its location.

## Usage Instructions

1. Export your ADV file to your desired location
2. Create a `Samples/Imported/` folder structure in the same directory
3. Copy or move your WAV files to the `Samples/Imported/` folder
4. Open the ADV file in Ableton Live

## Example

If you save your ADV file as `/Users/yourname/Music/MySampler.adv`, then your samples should be at:
- `/Users/yourname/Music/Samples/Imported/kick.wav`
- `/Users/yourname/Music/Samples/Imported/snare.wav`
- etc.

This ensures Ableton Live can find all the referenced samples when loading the preset.