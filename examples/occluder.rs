use bevy::prelude::*;
use bevy_light_2d::prelude::*;

fn main() {
    App::new()
        .add_plugins((DefaultPlugins, Light2dPlugin))
        .add_systems(Startup, setup)
        .add_systems(Update, move_occluder)
        .run()
}

fn setup(mut commands: Commands) {
    commands.spawn(Camera2dBundle::default());

    commands.spawn(PointLight2dBundle {
        point_light: PointLight2d {
            intensity: 3.0,
            radius: 400.0,
            ..default()
        },
        ..default()
    });

    commands.spawn(CircularOccluder2dBundle {
        circular_occluder: CircularOccluder2d {
            radius: 10.0,
            ..default()
        },
        transform: Transform::from_translation(Vec3::new(100.0, 50.0, 0.0)),
        ..default()
    });
}

fn move_occluder(mut query: Query<&mut Transform, With<CircularOccluder2d>>, time: Res<Time>) {
    for mut transform in &mut query.iter_mut() {
        transform.translation.x = time.elapsed_seconds().sin() * 100.0;
    }
}
